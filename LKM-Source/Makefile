rekernel_x-y := rkx.o rkx_genl.o rkx_netuid.o rkx_free_async.o rkx_frozen.o rkx_binder.o rkx_signal.o rkx_netfilter.o rkx_binder_kp.o rkx_binder_alloc.o

obj-m += rekernel_x.o

# Binder's private types must come from the target kernel, including for M= builds.
ccflags-y += -I$(srctree)/drivers/android

ifdef RKX_VERSION
ccflags-y += -DRKX_VERSION=\"$(RKX_VERSION)\"
endif
