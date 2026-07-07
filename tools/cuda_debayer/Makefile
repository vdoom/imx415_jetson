CUDA ?= /usr/local/cuda
NVCC := $(CUDA)/bin/nvcc
# Orin (Ampere iGPU) = sm_87
ARCH ?= -arch=sm_87

imx415_debayer: main.cu
	$(NVCC) -O3 $(ARCH) -o $@ $<

clean:
	rm -f imx415_debayer

.PHONY: clean
