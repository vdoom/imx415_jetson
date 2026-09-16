# Standalone build of nv_imx415.ko for JetPack 7 / L4T R39 (kernel 6.8.x),
# i.e. outside NVIDIA's nvidia-oot source tree. Works on the target itself
# (nvidia-l4t-kernel-headers + nvidia-l4t-kernel-oot-headers installed) or
# on a host holding the same two trees.
#
#   make            # conftest.h + nv_imx415.ko
#   make check      # + modversion CRC ground truth (see modcheck.sh)
#   make clean
#
# The in-BSP-tree build (copy sources next to nv_imx219.c, add one obj-m
# line - see Makefile.patch.note) still works and ignores this file.
NV_OOT ?= /usr/src/nvidia/nvidia-public

ifneq ($(KERNELRELEASE),)
# ---- Kbuild part -------------------------------------------------------
obj-m := nv_imx415.o
ccflags-y += -I$(NV_OOT)/include -I$(src)/include
ccflags-y += -Werror -Wmissing-prototypes
else
# ---- driver part -------------------------------------------------------
KDIR ?= /lib/modules/$(shell uname -r)/build
export NV_OOT KDIR
CONFTEST := include/nvidia/conftest.h

.PHONY: modules check clean
modules: $(CONFTEST)
	$(MAKE) -C $(KDIR) M=$(CURDIR) KBUILD_EXTRA_SYMBOLS=$(NV_OOT)/Module.symvers modules

$(CONFTEST): conftest.sh
	./conftest.sh $@

check: modules
	./modcheck.sh nv_imx415.ko

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
	rm -rf include
endif
