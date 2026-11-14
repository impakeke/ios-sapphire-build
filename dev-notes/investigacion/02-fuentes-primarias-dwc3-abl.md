# 02 — Fuentes primarias: DWC3, PHY femto y ABL de Qualcomm (2026-11-14)

**Origen.** Un agente Fable 5.2 investigó durante más de una hora, pero el límite de la API lo cortó antes de que escribiera el informe. Otro agente rescató su trabajo leyendo la transcripción, y **solo incluyó hechos con una fuente descargada en esa transcripción**. El agente original no dejó conclusiones propias: sus bloques de razonamiento estaban vacíos.

**Material crudo:** `~/sapphire-angel/research/investigacion-dwc3-abl/`. Contiene `transcripcion-agente-fable.jsonl`, `tr.txt` (la extracción, unas 21 mil líneas, se puede buscar con grep) e `idx.txt`.

**Reanudación:** el agente se puede reanudar con SendMessage a partir del 19 nov 11:00 (hora de Guayaquil), cuando se libera el límite de Fable.

Las citas de Linux corresponden al tag `v6.12` de torvalds/linux (raw.githubusercontent.com).

| Pregunta | Estado |
|---|---|
| P1 (CMDSTATUS=1) | Cubierta con fuente primaria |
| P2 (ciclo de vida / HWO) | Cubierta para Linux y U-Boot; **PENDIENTE** el orden HWO→evento según el databook |
| P3 (polling / caché / eventos perdidos) | Cubierta; **PENDIENTE** el gate de versión de EVNT_HANDLER_BUSY y la coherencia en SM6225 |
| P4 (ABL) | **Parcial:** código de ABL para fastboot, continue, reboot y ExitBootServices, más binarios stock desensamblados; sin el cuerpo de `PreparePlatformHardware`. El estado del PHY y de GCC en cada vía se midió en el teléfono (03 E2) |
| P5 (erratas/quirks) | Cubierta |

## P1. Start Transfer con status 1

- **`core.h`:**
  - `DWC3_DEPCMD_STATUS(x) (((x) >> 12) & 0x0F)`.
  - En "In response to Start Transfer": `DEPEVT_TRANSFER_NO_RESOURCE 1`, `DEPEVT_TRANSFER_BUS_EXPIRY 2`.
  - Por tanto, **status 1 = NO_RESOURCE**.
- **`gadget.c`, `dwc3_send_gadget_ep_cmd()` (L308-452):**
  - `timeout = 5000`.
  - `case DEPEVT_TRANSFER_NO_RESOURCE: dev_WARN(... "No resource for %s\n") ret = -EINVAL`.
  - `BUS_EXPIRY` → `-EAGAIN`, que solo aplica a isócronos.
  - Si el comando es STARTTRANSFER y tiene éxito, `dep->flags |= DWC3_EP_TRANSFER_STARTED`.
- **`__dwc3_gadget_kick_transfer()` (L1603-1676):**
  - `starting = !(dep->flags & DWC3_EP_TRANSFER_STARTED)`.
  - Si falla con algo distinto de `-EAGAIN`, llama a `dwc3_stop_active_transfer(dep, true, true)`.
- **Commit `f7ac582effc6`** (Thinh Nguyen, Synopsys, 2020). Enumera las causas de no-resource:
  > 1) The driver did not allocate resource for the endpoint during power-on-reset initialization. 2) The transfer resource was reset... START_CONFIG cmd to ep0 with resource index=2. 3) **The driver issues the START_TRANSFER command to an already started endpoint. Usually, this is because the END_TRANSFER command hasn't completed yet.**
- **Commit `5d2fb074dea2`** (2024): "Don't clear DWC3_EP_TRANSFER_STARTED flag to make sure that the driver won't send Start Transfer command again, which can cause no-resource error."
- **DEPCMD según Synopsys** (vía Xilinx UG1087, en web.archive.org): "CMDACT... The device controller sets this bit to 0 when the CmdStatus field is valid and the endpoint is ready to accept another command. **This does not imply that all the effects of the previously-issued command have taken place.**"
- **U-Boot** (v2024.10, `gadget.c` L905-907 y L960):
  - `if (start_new && (dep->flags & DWC3_EP_BUSY)) return -EBUSY;`
  - `EP_BUSY` solo se limpia en `dwc3_endpoint_transfer_complete()` (L1883-1885).
- **PENDIENTE:** la lista exhaustiva de causas según el databook 3.30a.

## P2. Ciclo de vida de una transferencia: HWO frente a XferComplete

- **`dwc3_gadget_ep_reclaim_completed_trb()` (L3346-3412).** Solo reclama al llegar el evento. Hace `if ((trb->ctrl & HWO) && status != -ESHUTDOWN) return 1;` y explica que "DWC3 will also avoid clearing HWO bit and SW has to do it manually" (en cadenas).
- **`dwc3_gadget_endpoint_transfer_complete()` (L3636-3648):** limpia `TRANSFER_STARTED` y vuelve a patear la transferencia si queda trabajo. No lo hace si está puesto `END_TRANSFER_PENDING`.
- **`dwc3_gadget_endpoint_command_complete()` (L3669-3712):** al terminar el End limpia `END_TRANSFER_PENDING` y `TRANSFER_STARTED`.
- **`__dwc3_stop_active_transfer()` (L1687-1729):** "When setting force, the ForceRM bit will be set... won't update the TRB progress... won't clear the HWO bit... will also not complete immediately". Pone `resource_index = 0`.
- **Barrera antes de HWO (L1338-1351):** "software must update the fourth DWORD of a TRB last". Después vienen `wmb(); trb->ctrl |= HWO`. Ver también el commit `117b4e96c7f3` (Qualcomm, 2022).
- **Commit `e0d19563eb6c`** (Synopsys, 2020): "If a transfer is in-progress, any new request should not kick off another transfer. The driver needs to wait for the current transfer to complete before starting off the next transfer."
- **Reset USB:** "Databook Rev. 3.30a Section 4.1.2 Table 4-2 ... the SW needs to ensure that it sends 'a DEPENDXFER command for any active transfers.'" Para soft disconnect, la sección 4.1.8 (Table 4-7).
- **Commit `d97c78a1908e`:** CLEAR_STALL va "_after_ the END_TRANSFER command completes".
- **U-Boot:** `dwc3_cleanup_done_reqs()` vuelca la caché del TRB antes de leerlo. XFERCOMPLETE pone `resource_index = 0`.
- **lk2nd** (`usb30_dwc.c`, MSM8916, **no es ABL**): usa la máquina de estados INACTIVE → START → XFER_IN_PROG → COMPLETE → INACTIVE, invalida la caché antes de leer HWO y limpia HWO a mano.
- **SIN FUENTE EN TRANSCRIPCIÓN:**
  - "emitir Start tras HWO=0 y antes del evento es ilegal". Sí está respaldado lo siguiente: Linux y U-Boot nunca emiten Start mientras el endpoint está STARTED/BUSY, y la causa 3 de f7ac582effc6.
  - El orden exacto entre el write-back del TRB y el evento: **PENDIENTE**.

## P3. Polling, caché y eventos "perdidos"

- **UG1087 (Synopsys):**
  - GEVNTSIZ bit 31: "prevents the interrupt... even when the mask is set, the events are queued."
  - GEVNTCOUNT: "When written, hardware decrements the count by the value written."
  - EVENTSIZ debe ser múltiplo de 4, con un mínimo de 32 B.
- **Linux, `gadget.c` L4382-4515:**
  - `check_event_buf` copia los eventos a una caché con wrap y escribe GEVNTCOUNT(count).
  - `lpos = (lpos + 4) % length`.
  - `GEVNTCOUNT_MASK 0xfffc`, `EHB BIT(31)`.
  - `EVENT_BUFFERS_SIZE 4096`.
- **Memoria:** Linux usa `dma_alloc_coherent()` para los TRB (`gadget.c` L493) y los eventos (`core.c` L488). En arm64, `pgprot_dmacoherent = MT_NORMAL_NC`.
- **U-Boot v2024.10:**
  - Usa memoria cacheable con `flush_dcache_range` manual.
  - En `dwc3_gadget_uboot_handle_interrupt` (L2741-2757), tras procesar: "Clean + Invalidate the buffers after touching them".
  - Vuelca los TRB después de poner HWO (L816-819).
- **barebox v2024.10.0 (polled):** `dwc3_gadget_poll()` → `dwc3_check_event_buf()` con `memcpy_fromio`.
- **"Eventos perdidos" documentados:** en todos los casos son **bugs de driver o de manejo de IRQ**, no del hardware:
  - `d325a1de49d6` (2017): el top-half sobrescribe eventos no procesados → "hang in the file transfer".
  - `7441b273388b` (2022): pérdida de sincronía entre controlador y driver.
  - `28632b44d129` (2016): STAR 9000961433, solo afecta a la versión **3.00a** (aquí la versión es 3.30a).
- **El binario stock de Qualcomm** `UsbfnDwc3Dxe.efi` contiene la cadena "EVENT BUFFER OVERFLOW!! Some events may have been dropped".
- **PENDIENTE:** el gate de versión de EVNT_HANDLER_BUSY y la coherencia de DMA del DWC3 en SM6225.

## P4. ABL, USB y PHY

### Código fuente de ABL

Repositorio: `git.codelinaro.org/clo/la/abl/tianocore/edk2`, proyecto 12946, ref `LA.UM.9.15.2.r1-12000-KAMORTA.QISI14.0` (2023-06-26). No hay tag KHAJE/BENGAL.

- **`FastbootMain.c`:**
  - L141-155: `InitUsbControllerGuid` → `CreateEventEx` + `SignalEvent` + `CloseEvent`.
  - `LocateProtocol(UsbDeviceProtolGuid)`; L197 `StartEx(&DescSet)`.
  - L227-229: `FastbootUsbDeviceStop` **solo libera los buffers TX/RX**.
  - L373: bucle `HandleUsbEvents()` hasta "Continue detected, Exiting App", luego `FastbootUsbDeviceStop()`.
  - **ABL no contiene el driver DWC3**: usa el protocolo UEFI de un DXE.
- **`FastbootCmds.c`:**
  - `CmdReboot` → `RebootDevice(NORMAL_MODE)`, sin parar el USB.
  - `CmdContinue` → `LoadImageAndAuth`, `FastbootOkay`, `FastbootUsbDeviceStop()` y `BootLinux(&Info)`. `CmdBoot` hace lo mismo.
- **`LinuxLoader.c` L296-336:** `if (!BootIntoFastboot) { LoadImageAndAuth; BootLinux; }`. Solo en caso de fallo hace `goto fastboot` → `FastbootInitialize()`. Es decir, **en arranque normal ABL no arranca el USB device**.
- **`BootLinux.c` L1061-1072:** `ShutdownUefiBootServices()` (`ExitBootServices`) → `PreparePlatformHardware()`. **No se obtuvo** el cuerpo de esta última función.

### Binarios UEFI stock (desensamblados; no hay fuente)

Origen: `Project-Silicium/Device-Binaries` @af63402ef522, `tapas/QcomPkg/Drivers/...`. Las rutas internas son `non-hlos-sm6225/BOOT.XF.4.` y `DivarPkg/Library/UsbConfigLib/UsbConfigUsbCores.c`. **NO CONFIRMADO** que sea el mismo firmware del teléfono.

- **`UsbConfigDxe.efi`:**
  - Registra un evento de ExitBootServices.
  - Tabla de funciones: `SSUsb1InitCommon`, `Usb30InitDevice`, `Usb30GetVbusSt`, `Usb30EnableVbus`, `Usb30Reset`, `Usb30ResetSSPhy`, `SSUsb1SetPhyNonDrivingMode`, `UsbConfigCoresDeinit`.
  - Según el agente, que lo **infiere**, el manejador de ExitBootServices llama a `UsbConfigCoresDeinit`.
  - Cadenas: `gcc_usb30_prim_*`, `usb30_prim_gdsc`, `InitHSUSBPhy`, "failed to get the Vbus state".
- **`UsbfnDwc3Dxe.efi`:**
  - `UsbfnExitBootService` @0x1bb0 vacía las colas de 16×2 EP, sigue la ruta de "cable disconnect" y llama a `UsbfnDwcFreeXferRsc`.
  - Cadenas: "StartXfer command failed on physical endpoint %d, EventStatus: %d", "End Transfer Command on Ep %d... timed out", "Timed out waiting for controller to halt".
- **Comunidad** (Project-Aloha, Sm8150/Sm7125, otra familia): "Exit BootServices routine was patched to not deinit USB after exit boot services". Es evidencia indirecta de que el stock **sí** desinicializa el USB en ExitBootServices.

### Secuencias de inicialización (Linux / CodeLinaro)

- **`dwc3-qcom.c` v6.12:**
  - QSCRATCH en `0xf8800`.
  - `GENERAL_CFG 0x08`: `PIPE_UTMI_CLK_SEL` BIT0, `PIPE3_PHYSTATUS_SW` BIT3, `PIPE_UTMI_CLK_DIS` BIT8.
  - `HS_PHY_CTRL 0x10`: `UTMI_OTG_VBUS_VALID` BIT20, `SW_SESSVLD_SEL` BIT28.
  - `SS_PHY_CTRL 0x30`: `LANE0_PWR_PRESENT` BIT24.
  - Hace el override de VBUS en modo dispositivo.
  - Reset: assert, 10-1000 µs, deassert.
  - El binding `qcom,select-utmi-as-pipe-clk` sirve para "dwc3 operates without SSPHY and only HS/FS/LS".
- **`phy-qcom-snps-femto-v2.c` v6.12, `qcom_snps_hsphy_init()` (L386-477), en este orden:**
  1. reguladores, relojes, reset (100-150 µs);
  2. `CFG0 OVERRIDE_EN`, `UTMI_CTRL5 POR=1`, `COMMON0 FSEL=0`, `COMMON1 PLLBTUNE`, `REFCLK_CTRL`;
  3. `VBUSVLDEXTSEL0`, `HS_PHY_CTRL1 VBUSVLDEXT0`, overrides, `COMMON2 VREGBYPASS`;
  4. `HS_PHY_CTRL2 SUSPEND_N_SEL|SUSPEND_N`, `UTMI_CTRL0 SLEEPM`, `COMMON0 SIDDQ=0`;
  5. `UTMI_CTRL5 POR=0`, `HS_PHY_CTRL2 SUSPEND_N_SEL=0`, `CFG0 OVERRIDE_EN=0`.
- **Offsets del PHY:** `UTMI_CTRL0 0x3c`, `CTRL5 0x50`, `COMMON0 0x54` (SIDDQ BIT2), `COMMON1 0x58`, `COMMON2 0x5c`, `HS_PHY_CTRL1 0x60`, `HS_PHY_CTRL2 0x64`, overrides `0x6c-0x78`, `CFG0 0x94`, `REFCLK 0xa0`.
- **Downstream** (`kernel.lnx.5.15.r66-rel`, `phy-msm-snps-hs.c`): `msm_hsphy_init()` es igual, con `PWRDOWN_CTRL 0xa4 PWRDOWN_B` y manejo de EUD.
- **DT `qcom/khaje-usb.dtsi`** (CodeLinaro, `kernel.lnx.5.15.r66-rel`):
  - `hsphy@1613000` con compatible `"qcom,usb-hsphy-snps-femto"`.
  - Alimentaciones: `vdd=L4A`, `vdda18=L12A`, `vdda33=L15A`.
  - Relojes: XO, `GCC_USB3_PRIM_CLKREF_CLK`, `GCC_AHB2PHY_USB_CLK`.
  - Reset: `GCC_QUSB2PHY_PRIM_BCR`.
  - `param-override-seq = <0xa6 0x6c>,<0x85 0x70>,<0x16 0x74>`.
  - DWC3 en `0x4e00000` con `snps,disable-clk-gating`, `has-lpm-erratum`, `hird-threshold 0x10`, `dr_mode="otg"`.
  - L4A: 0,72-1,05 V; L12A: 1,62-1,98 V.
- **Mainline `sm6115.dtsi`:** declara el PHY como **qusb2** (no femto) y usa `snps,dis_u2_susphy_quirk; snps,dis_enblslpm_quirk; snps,has-lpm-erratum; ...`. No existe `sm6225.dtsi`.
- **GCC** (`gcc-sm6115.c` = `gcc-khaje.c`):
  - Ramas: `ahb2phy_usb 0x1d008`, `cfg_noc_usb3_prim_axi 0x1a084`, `sys_noc 0x1a080`, `master 0x1a010`, `mock_utmi 0x1a018`, `sleep 0x1a014`, `clkref 0x9f000`, `gdsc 0x1a004`.
  - Resets: `QUSB2PHY_PRIM_BCR 0x1c000`, `USB30_PRIM_BCR 0x1a000`, `AHB2PHY_BCR 0x1d000`.

### ¿Encaja "timeout de Set Endpoint Config en ep0" con un PHY o reloj ausente?

Sí. Las fuentes de abajo lo apoyan en general, y en el teléfono se midió (03 E2-E3): en la ruta normal el reloj PIPE del PHY USB3 está apagado, y seleccionar UTMI como reloj PIPE (`dwc3_qcom_select_utmi_clk`) elimina el timeout.

- **UG1087, GUSB2PHYCFG ENBLSLPM[8]:** "Before issuing any device endpoint command when operating in 2.0 speeds, disable this bit... if mac2_clk (utmi_clk) is gated off, the command will not get completed."
- **Linux `gadget.c` L320-329** cita la "DWC_usb3 3.30a programming guide section 3.2.2".
- **`1c0e69ae1b9f`:** sin pipe_clk, el controlador usa suspend_clk y los comandos tardan más.
- **`6d735722063a`** (2024): "Suspend during initialization can result in undefined behavior due to clock synchronization failure".

### Hechos clave de P4

1. **En arranque normal, ABL NO arranca el USB device** (`LinuxLoader.c`).
2. **`continue`/`boot`** solo liberan los buffers → `BootLinux` → `ExitBootServices` → `PreparePlatformHardware`. **`reboot`** hace `ResetSystem` sin parar el USB.
3. Los DXE stock registran limpieza en ExitBootServices. Que sea un deinit completo es inferencia, y no se sabe qué registros toca. *Observación propia de C1: tras `continue`, el DWC3 seguía configurado (DCFG, DEVTEN y DALEPENA puestos, buffer de eventos del ABL), así que esa limpieza no lo resetea.*
4. Un SO independiente necesita: el GDSC y los relojes de GCC, el reset `QUSB2PHY_PRIM_BCR`, los reguladores L4A/L12A/L15A, la secuencia del PHY femto y el override de VBUS en QSCRATCH.

5. *Medido en el teléfono (03 E1-E3):* el PHY femto queda inicializado igual en ambas vías; en arranque normal el reloj PIPE del PHY USB3 (GCC CBCR 0x1a058) está apagado y `GENERAL_CFG` no selecciona UTMI. VBUS no influye.

**PENDIENTE:**

- `PreparePlatformHardware`;
- qué toca el deinit de `UsbConfigDxe` en ExitBootServices;
- la fuente de los DXE.

## P5. Erratas y quirks

- **Binding `snps,dwc3.yaml`:**
  - `snps,usb2-gadget-lpm-disable`;
  - `snps,dis_u2_susphy_quirk` ("disable USB2 suspend phy");
  - `snps,dis_enblslpm_quirk` ("clears the enblslpm in GUSB2PHYCFG, disabling the suspend signal to the PHY");
  - `snps,has-lpm-erratum`.
- **`core.c`:**
  - `dwc3_hs_phy_setup()` L759-764: `SUSPHY` se borra, y `ENBLSLPM` se borra si está el quirk.
  - L86-93: desde 3.30a no hay OTG.
  - L1385-1392: ENDXFER polling desde 3.10a (`RST_ACTBITLATER`).
  - `dwc3_core_soft_reset()`: 1000 reintentos de `udelay(1)`.
- **`gadget.c`:**
  - L4145-4184: en conndone, LPM se habilita salvo `usb2_gadget_lpm_disable`.
  - L330-345 y L445-449: borra `ENBLSLPM`/`SUSPHY` antes de cada comando EP y lo restaura después.
- **Commits:**
  - `87dd96111b0b`, `2b0f11df84bb`: SUSPHY/ENBLSLPM antes de los comandos.
  - `4749e0e61241`: el soft reset puede tardar ~50 ms.
  - `6d735722063a`.
- **PENDIENTE:** STARs específicos de 3.30a.

## URLs

- **Funcionaron:** raw.githubusercontent.com/torvalds/linux/v6.12 y v7.4-rc2; los patches de los commits citados; U-Boot v2024.10 y v2025.01; barebox v2024.10.0; la API v4 de CodeLinaro (ABL proyecto 12946, `kernel-devicetree` 83793, `msm-5.15` 53431); Project-Silicium/Device-Binaries; Project-Aloha; lk2nd; web.archive.org con UG1087.
- **Fallaron:** el raw de CodeLinaro (429), la búsqueda de CodeLinaro (401), grep.app, Sourcegraph (0), la búsqueda de commits en GitHub (rate limit), docs.amd.com (solo JS), y varios 404 (`sm6225.dtsi`, lk2nd `dwc.c`, Zephyr).
