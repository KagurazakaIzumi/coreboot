ifeq ($(CONFIG_SOUTHBRIDGE_NVIDIA_MCP55),y)

ramstage-y += mcp55.c
ramstage-y += azalia.c
ramstage-y += ht.c
ramstage-y += ide.c
ramstage-y += lpc.c
ramstage-y += nic.c
ramstage-y += pci.c
ramstage-y += pcie.c
ramstage-y += sata.c
ramstage-y += smbus.c
ramstage-y += usb2.c
ramstage-y += usb.c

ramstage-$(CONFIG_HAVE_ACPI_TABLES) += fadt.c

ramstage-y += reset.c

bootblock-y += enable_usbdebug.c
romstage-y += enable_usbdebug.c
ramstage-y += enable_usbdebug.c
romstage-y += early_smbus.c
romstage-y += early_ctrl.c

ifeq ($(CONFIG_MCP55_USE_AZA),y)
ramstage-srcs += src/mainboard/$(MAINBOARDDIR)/hda_verb.c
endif

bootblock-y += romstrap.ld
bootblock-y += romstrap.S

endif
