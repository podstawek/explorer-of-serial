# Link to device X and monitor boot identification

## Host-side bridge (Pi 4, /boot/config.txt)
Command: ssh pi 'grep -v "^#" /boot/config.txt | grep -v "^$"'
    dtparam=audio=on
    [pi4]
    dtoverlay=vc4-fkms-v3d
    max_framebuffers=2
    [all]
    enable_uart=1
    dtoverlay=sc16is752-spi1,int_pin=24

DT node: /sys/firmware/devicetree/base/soc/spi@7e215080/sc16is752@0
compatible = "nxp,sc16is752"; clock 14.7456 MHz; SPI 4 MHz; IRQ GPIO24.
=> Pi --SPI--> SC16IS752 UART/HAT --UART A(/dev/ttySC0)--> device X.
/dev/ttySC1: completely silent (passive listen + active BREAK at all bauds).

## X responds at /dev/ttySC0, 4800 baud 8N1
BREAK -> "\r\n\n\nBREAK\r\n\n\r\nTUTOR  1.3 > "
Unknown char -> "WHAT\r\n" then prompt.
Prompt: "TUTOR  1.3 > "  (string also found in ROM at $0082FC)

## No emulator on the Pi (X is hardware)
Command: ssh pi 'ps aux --sort=-%cpu | head -15'
-> only my own python3 probe scripts + standard Pi services; no emulator process.
