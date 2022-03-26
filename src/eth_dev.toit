import gpio show Pin
import spi
import net.ethernet
import log
import net

class EthernetDevice:
  logger_/log.Logger ::= log.default.with_name "ethdev"

  vspi_clk/Pin := Pin 18
  vspi_mosi/Pin := Pin 19
  vspi_miso/Pin := Pin 21
  vspi_phys_cs/Pin := Pin 5
  phy_enable := Pin.out 25
  phy_interrupt := Pin 36

  vspi_bus/spi.Bus
  phy_spi_device/spi.Device

  ethernet_/net.Interface? := null

  constructor:
    vspi_bus     = spi.Bus --clock=vspi_clk --mosi=vspi_mosi --miso=vspi_miso
    phy_spi_device = vspi_bus.device
        --cs=vspi_phys_cs
        --frequency=20_000_000
        --mode=0
        --command_bits=16
        --address_bits=8

    ethernet_ = ethernet.connect
        --phy_chip = ethernet.PHY_CHIP_NONE
        --mac_chip = ethernet.MAC_CHIP_W5500
        --mac_spi_device = phy_spi_device
        --mac_int = phy_interrupt
        --mac_mdc = null
        --mac_mdio = null

    start_phy

    print "Ethernet is running"

  start_phy:
    logger_.info "Starting phy"
    print "Starting phy"
    phy_enable.set 1
    //pca9570.set_io phy_enable_expander_pin 1

  stop_phys:
    logger_.info "Starting phys"
    phy_enable.set 0
    //pca9570.set_io phy_enable_expander_pin 0
