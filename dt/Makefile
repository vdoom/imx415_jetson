# Standalone build of the IMX415 camera overlay (JetPack 7 / L4T R39), i.e.
# without the Jetson Linux BSP tree: only cpp, dtc, the installed kernel
# headers (for dt-bindings) and the local include/ stand-in are needed.
#
#   make              # tegra234-p3767-camera-p3768-imx415.dtbo
#   make check        # apply it to the installed base DTB (fixups resolve?)
#   make decompile    # refresh imx415-overlay-decompiled.dts for review
#   make clean
#
# In the BSP tree (hardware/nvidia/t23x/nv-public/overlay + one dtbo-y line)
# the same .dts builds unchanged; this file is not used there.
KDIR ?= /lib/modules/$(shell uname -r)/build
DTS  := tegra234-p3767-camera-p3768-imx415.dts
DTBO := $(DTS:.dts=.dtbo)
BASE_DTB ?= $(firstword $(wildcard /boot/dtb/kernel_tegra234-p3768-0000+p3767-*.dtb))

CPPFLAGS := -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
            -I include -I $(KDIR)/include
# same warning set the kernel uses for overlays
DTCFLAGS := -@ -Wno-unit_address_vs_reg -Wno-simple_bus_reg \
            -Wno-unique_unit_address -Wno-avoid_unnecessary_addr_size \
            -Wno-alias_paths -Wno-graph_child_address \
            -Wno-interrupt_provider -Wno-unit_address_format

.PHONY: all check decompile clean
all: $(DTBO)

$(DTBO): $(DTS) include/dt-bindings/tegra234-p3767-0000-common.h Makefile
	cpp $(CPPFLAGS) $< | dtc $(DTCFLAGS) -I dts -O dtb -o $@ -

check: $(DTBO)
	@test -n "$(BASE_DTB)" || { echo "no base DTB found, set BASE_DTB=" >&2; exit 1; }
	fdtoverlay -i $(BASE_DTB) -o /dev/null $(DTBO) && echo "overlay applies cleanly to $(BASE_DTB)"

decompile: $(DTBO)
	dtc -I dtb -O dts -o imx415-overlay-decompiled.dts $(DTBO)

clean:
	rm -f $(DTBO)
