// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import http
import log
import net
import net.udp
import net.tcp
import reader
import uuid
import monitor

import encoding.ubjson
import encoding.tison

import system.assets
import system.containers
import system.firmware

import .container_registry

HTTP_PORT        ::= 9000
IDENTIFY_PORT    ::= 1990
IDENTIFY_ADDRESS ::= net.IpAddress.parse "255.255.255.255"
STATUS_OK_JSON   ::= """{ "status": "OK" }"""

HEADER_DEVICE_ID         ::= "X-Jaguar-Device-ID"
HEADER_SDK_VERSION       ::= "X-Jaguar-SDK-Version"
HEADER_DISABLED          ::= "X-Jaguar-Disabled"
HEADER_CONTAINER_NAME    ::= "X-Jaguar-Container-Name"
HEADER_CONTAINER_TIMEOUT ::= "X-Jaguar-Container-Timeout"

// Defines recognized by Jaguar for /run and /install requests.
JAG_DISABLED ::= "jag.disabled"
JAG_TIMEOUT  ::= "jag.timeout"

// Assets for the mini-webpage that the device serves up on $HTTP_PORT.
CHIP_IMAGE ::= "https://toitlang.github.io/jaguar/device-files/chip.svg"
STYLE_CSS ::= "https://toitlang.github.io/jaguar/device-files/style.css"

logger ::= log.Logger log.INFO_LEVEL log.DefaultTarget --name="jaguar"
flash_mutex ::= monitor.Mutex

firmware_is_validation_pending / bool := firmware.is_validation_pending
firmware_is_upgrade_pending / bool := false

/**
Jaguar can run containers while Jaguar itself is disabled. You can
  enable this behavior by using `jag run -D jag.disabled ...` when
  starting the container. Use this mode to test how your apps behave
  when they run with no pre-established network.

We keep track of the state through the global $disabled variable and
  we set this to true when starting a container that needs to run with
  Jaguar disabled. In return, this makes the outer $serve loop wait
  for the container to be done, before it re-establishes the network
  connection and restarts the HTTP server.
*/
disabled / bool := false
network_free   / monitor.Semaphore ::= monitor.Semaphore
container_done / monitor.Semaphore ::= monitor.Semaphore

// The installed and named containers are kept in a registry backed
// by the flash (on the device).
registry_ / ContainerRegistry ::= ContainerRegistry

main arguments:
  try:
    // We try to start all installed containers, but we catch any
    // exceptions that might occur from that to avoid blocking
    // the Jaguar functionality in case something is off.
    catch --trace: run_installed_containers
    // We are now ready to start Jaguar.
    serve arguments
  finally: | is_exception exception |
    // We shouldn't be able to get here without an exception having
    // been thrown, but we play it defensively and force an exception
    // if that should ever happen.
    if not is_exception: unreachable
    // Jaguar runs as a critical container, so an uncaught exception
    // will cause the system to reboot.
    logger.error "rebooting due to $exception.value"

run_installed_containers -> none:
  blockers ::= []
  registry_.do: | name/string image/uuid.Uuid defines/Map? |
    start ::= Time.monotonic_us
    container := run_image image "started" name defines
    if defines.get JAG_DISABLED:
      timeout/Duration ::= compute_timeout defines --disabled
      blockers.add:: run_to_completion name container start timeout
  if blockers.is_empty: return
  // We have a number of containers that we need to allow
  // to run to completion before we return and let Jaguar
  // start serving requests.
  semaphore := monitor.Semaphore
  blockers.do: | lambda/Lambda |
    task::
      try:
        lambda.call
      finally:
        semaphore.up
  blockers.size.repeat: semaphore.down

serve arguments:
  device := Device.parse arguments
  while true:
    attempts ::= 3
    failures := 0
    while failures < attempts:
      exception := catch: run device
      // If we have a pending firmware upgrade, we take care of
      // it before trying to re-open the network.
      if firmware_is_upgrade_pending: firmware.upgrade
      // If Jaguar needs to be disabled, we stop here and wait until
      // we can re-enable Jaguar.
      if disabled:
        network_free.up      // Signal to start running the container.
        container_done.down  // Wait until done running the container.
        disabled = false
        continue
      // Log exceptions and count the failures so we can back off
      // and avoid excessive attempts to re-open the network.
      if exception:
        failures++
        logger.warn "running Jaguar failed due to '$exception' ($failures/$attempts)"
    // If we need to validate the firmware and we've failed to do so
    // in the first round of attempts, we roll back to the previous
    // firmware right away.
    if firmware_is_validation_pending:
      logger.error "firmware update was rejected after failing to connect or validate"
      firmware.rollback
    backoff := Duration --s=5
    logger.info "backing off for $backoff"
    sleep backoff

class Device:
  id/uuid.Uuid
  name/string
  port/int
  chip/string
  constructor --.id --.name --.port --.chip:

  static parse arguments -> Device:
    config := {:}
    if platform == PLATFORM_FREERTOS:
      assets.decode.get "config" --if_present=: | encoded |
        catch: config = tison.decode encoded

    id/uuid.Uuid? := null
    if arguments.size >= 2:
      id = uuid.parse arguments[1]
    else:
      id = config.get "id" --if_present=: uuid.parse it

    name/string? := null
    if arguments.size >= 3:
      name = arguments[2]
    else:
      name = config.get "name"

    port := HTTP_PORT
    if arguments.size >= 1:
      port = int.parse arguments[0]

    chip/string? := config.get "chip"

    return Device
        --id=id or uuid.NIL
        --name=name or "unknown"
        --port=port
        --chip=chip or "unknown"

run device/Device:
  network ::= net.open
  socket/tcp.ServerSocket? := null
  try:
    socket = network.tcp_listen device.port
    address := "http://$network.address:$socket.local_address.port"
    logger.info "running Jaguar device '$device.name' (id: '$device.id') on '$address'"

    // We've successfully connected to the network, so we consider
    // the current firmware functional. Go ahead and validate the
    // firmware if requested to do so.
    if firmware_is_validation_pending:
      if firmware.validate:
        logger.info "firmware update validated after connecting to network"
        firmware_is_validation_pending = false
      else:
        logger.error "firmware update failed to validate"

    // We run two tasks concurrently: One broadcasts the device identity
    // via UDP and one serves incoming HTTP requests. We run the tasks
    // in a group so if one of them terminates, we take the other one down
    // and clean up nicely.
    Task.group --required=1 [
      :: broadcast_identity network device address,
      :: serve_incoming_requests socket device address,
    ]
  finally:
    if socket: socket.close
    network.close

flash_image image_size/int reader/reader.Reader name/string? defines/Map -> uuid.Uuid:
  with_timeout --ms=120_000: flash_mutex.do:
    image := registry_.install name defines:
      logger.debug "installing container image with $image_size bytes"
      written_size := 0
      writer := containers.ContainerImageWriter image_size
      while data := reader.read:
        // This is really subtle, but because the firmware writing crosses the RPC
        // boundary, the provided data might get neutered and handed over to another
        // process. In that case, the size after the call to writer.write is zero,
        // which isn't great for tracking progress. So we update the written size
        // before calling out to writer.write.
        written_size += data.size
        writer.write data
      logger.debug "installing container image with $image_size bytes -> wrote $written_size bytes"
      writer.commit --data=(name != null ? JAGUAR_INSTALLED_MAGIC : 0)
    return image
  unreachable

run_image image/uuid.Uuid cause/string name/string? defines/Map -> containers.Container:
  nick := name ? "container '$name'" : "program $image"
  suffix := defines.is_empty ? "" : " with $defines"
  logger.info "$nick $cause$suffix"
  return containers.start image

install_image image_size/int reader/reader.Reader name/string defines/Map -> none:
  image := flash_image image_size reader name defines
  if defines.get JAG_DISABLED:
    logger.info "container '$name' installed with $defines"
    logger.warn "container '$name' needs reboot to start with Jaguar disabled"
  else:
    timeout := compute_timeout defines --no-disabled
    if timeout: logger.warn "container '$name' needs 'jag.disabled' for 'jag.timeout' to take effect"
    run_image image "installed and started" name defines

uninstall_image name/string -> none:
  with_timeout --ms=60_000: flash_mutex.do:
    if image := registry_.uninstall name:
      logger.info "container '$name' uninstalled"
    else:
      logger.error "container '$name' not found"

compute_timeout defines/Map --disabled/bool -> Duration?:
  jag_timeout := defines.get JAG_TIMEOUT
  if jag_timeout is int and jag_timeout > 0:
    return Duration --s=jag_timeout
  else if jag_timeout:
    logger.error "invalid $JAG_TIMEOUT setting ($jag_timeout)"
  return disabled ? (Duration --s=10) : null

run_to_completion name/string? container/containers.Container start/int timeout/Duration?:
  nick := name ? "container '$name'" : "program $container.id"

  // We're only interested in handling the timeout errors, so we
  // unwind and produce a stack trace in all other cases.
  filter ::= : it != DEADLINE_EXCEEDED_ERROR

  // Wait until the container is done or until we time out.
  code/int? := null
  catch --unwind=filter --trace=filter:
    with_timeout timeout: code = container.wait
  if not code:
    elapsed ::= Duration --us=Time.monotonic_us - start
    code = container.stop
    logger.info "$nick timed out after $elapsed"

  if code == 0:
    logger.info "$nick stopped"
  else:
    logger.error "$nick stopped - exit code $code"

run_code image_size/int reader/reader.Reader defines/Map -> none:
  jag_disabled := defines.get JAG_DISABLED
  if jag_disabled: disabled = true
  timeout/Duration? := compute_timeout defines --disabled=disabled

  // Write the image into flash.
  image := flash_image image_size reader null defines

  // We start the container from a separate task to allow the HTTP server
  // to continue operating. This also means that the container running
  // isn't covered by the flashing mutex or associated timeout.
  task::
    // First, we wait until we're ready to run the container. Usually,
    // we are ready right away, but if we've been asked to disable
    // Jaguar while running the container, we wait until the HTTP server
    // has been shut down and the network to be free.
    if disabled: network_free.down

    // Start the image and wait for it to complete.
    start ::= Time.monotonic_us
    container ::= run_image image "started" null defines
    run_to_completion null container start timeout

    // If Jaguar was disabled while running the container, now is the
    // time to restart the HTTP server.
    if disabled: container_done.up

install_firmware firmware_size/int reader/reader.Reader -> none:
  with_timeout --ms=300_000: flash_mutex.do:
    logger.info "installing firmware with $firmware_size bytes"
    written_size := 0
    writer := firmware.FirmwareWriter 0 firmware_size
    try:
      last := null
      while data := reader.read:
        written_size += data.size
        writer.write data
        percent := (written_size * 100) / firmware_size
        if percent != last:
          logger.info "installing firmware with $firmware_size bytes ($percent%)"
          last = percent
      writer.commit
      logger.info "installed firmware; ready to update on chip reset"
    finally:
      writer.close

identity_payload device/Device address/string -> ByteArray:
  identity := """
    { "method": "jaguar.identify",
      "payload": {
        "name": "$device.name",
        "id": "$device.id",
        "chip": "$device.chip",
        "sdkVersion": "$vm_sdk_version",
        "address": "$address",
        "wordSize": $BYTES_PER_WORD
      }
    }
  """
  return identity.to_byte_array

broadcast_identity network/net.Interface device/Device address/string -> none:
  payload ::= identity_payload device address
  datagram ::= udp.Datagram
      payload
      net.SocketAddress IDENTIFY_ADDRESS IDENTIFY_PORT
  socket := network.udp_open
  try:
    socket.broadcast = true
    while not network.is_closed:
      socket.send datagram
      sleep --ms=200
  finally:
    socket.close

handle_browser_request name/string request/http.Request writer/http.ResponseWriter -> none:
  path := request.path
  if path == "/": path = "index.html"
  if path.starts_with "/": path = path[1..]

  if path == "index.html":
    uptime ::= Duration --s=Time.monotonic_us / Duration.MICROSECONDS_PER_SECOND

    writer.headers.set "Content-Type" "text/html"
    writer.write """
        <html>
          <head>
            <link rel="stylesheet" href="$STYLE_CSS">
            <title>$name (Jaguar device)</title>
          </head>
          <body>
            <div class="box">
              <section class="text-center">
                <img src="$CHIP_IMAGE" alt="Picture of an embedded device" width=200>
              </section>
              <h1 class="mt-40">$name</h1>
              <p class="text-center">Jaguar device</p>
              <p class="hr mt-40"></p>
              <section class="grid grid-cols-2 mt-20">
                <p>Uptime</p>
                <p><b class="text-black">$uptime</b></p>
                <p>SDK</p>
                <p><b class="text-black">$vm_sdk_version</b></p>
              </section>
              <p class="hr mt-20"></p>
              <p class="mt-40">Run code on this device using</p>
              <b><a href="https://github.com/toitlang/jaguar">&gt; jag run -d $name hello.toit</a></b>
              <p class="mt-20">Monitor the serial port console using</p>
              <p class="mb-20"><b><a href="https://github.com/toitlang/jaguar">&gt; jag monitor</a></b></p>
            </div>
          </body>
        </html>
        """
  else if path == "favicon.ico":
    writer.redirect http.STATUS_FOUND CHIP_IMAGE
  else:
    writer.headers.set "Content-Type" "text/plain"
    writer.write_headers http.STATUS_NOT_FOUND
    writer.write "Not found: $path"

serve_incoming_requests socket/tcp.ServerSocket device/Device address/string -> none:
  self := Task.current

  server := http.Server --logger=logger

  server.listen socket:: | request/http.Request writer/http.ResponseWriter |
    headers ::= request.headers
    device_id := "$device.id"
    device_id_header := headers.single HEADER_DEVICE_ID
    sdk_version_header := headers.single HEADER_SDK_VERSION
    path := request.path

    // Handle identification requests before validation, as the caller doesn't know that information yet.
    if path == "/identify" and request.method == http.GET:
      writer.headers.set "Content-Type" "application/json"
      result := identity_payload device address
      writer.headers.set "Content-Length" result.size.stringify
      writer.write result

    else if path == "/" or path.ends_with ".html" or path.ends_with ".css" or path.ends_with ".ico":
      handle_browser_request device.name request writer

    // Validate device ID.
    else if device_id_header != device_id:
      logger.info "denied request, header: '$HEADER_DEVICE_ID' was '$device_id_header' not '$device_id'"
      writer.write_headers http.STATUS_FORBIDDEN --message="Device has id '$device_id', jag is trying to talk to '$device_id_header'"

    // Handle pings.
    else if path == "/ping" and request.method == http.GET:
      respond_ok writer

    // Handle listing containers.
    else if path == "/list" and request.method == http.GET:
      result := ubjson.encode registry_.entries
      writer.headers.set "Content-Type" "application/ubjson"
      writer.headers.set "Content-Length" result.size.stringify
      writer.write result

    // Handle uninstalling containers.
    else if path == "/uninstall" and request.method == http.PUT:
      container_name ::= headers.single HEADER_CONTAINER_NAME
      uninstall_image container_name
      respond_ok writer

    // Handle firmware updates.
    else if path == "/firmware" and request.method == http.PUT:
      install_firmware request.content_length request.body
      respond_ok writer
      // Mark the firmware as having a pending upgrade and close
      // the server socket to force the HTTP sever loop to stop.
      firmware_is_upgrade_pending = true
      socket.close

    // Validate SDK version before attempting to install containers or run code.
    else if sdk_version_header != vm_sdk_version:
      logger.info "denied request, header: '$HEADER_SDK_VERSION' was '$sdk_version_header' not '$vm_sdk_version'"
      writer.write_headers http.STATUS_NOT_ACCEPTABLE --message="Device has $vm_sdk_version, jag has $sdk_version_header"

    // Handle installing containers.
    else if path == "/install" and request.method == "PUT":
      container_name ::= headers.single HEADER_CONTAINER_NAME
      defines ::= extract_defines headers
      install_image request.content_length request.body container_name defines
      respond_ok writer

    // Handle code running.
    else if path == "/run" and request.method == "PUT":
      defines ::= extract_defines headers
      run_code request.content_length request.body defines
      respond_ok writer
      // If the code needs to run with Jaguar disabled, we close
      // the server socket to force the HTTP sever loop to stop.
      if disabled: socket.close

extract_defines headers/http.Headers -> Map:
  defines := {:}
  if headers.single HEADER_DISABLED:
    defines[JAG_DISABLED] = true
  if header := headers.single HEADER_CONTAINER_TIMEOUT:
    timeout := int.parse header --on_error=: null
    if timeout: defines[JAG_TIMEOUT] = timeout
  return defines

respond_ok writer/http.ResponseWriter -> none:
  writer.headers.set "Content-Type" "application/json"
  writer.headers.set "Content-Length" STATUS_OK_JSON.size.stringify
  writer.write STATUS_OK_JSON
