# Паспорт проєкту IMX415 → Jetson Orin Nano — дані з target

**Дата збору:** 2026-07-06 · **Хто збирав:** Claude Code безпосередньо на target (`orca@tegra-ubuntu`)
**Покриває:** guide §1.4 (знімок стану), §3.2 (I2C smoke test) + додаткова розвідка DT/GPIO.
**Повторна верифікація 2026-07-07:** усі значення відтворились 1:1 (скани, регістрові
читання, GPIO-карта, extlinux незмінний). Додатково: повний скан 0x08–0x77 з XCLR=1,
розбір донорського `imx219-C.dtbo` (розділ 5.1), уточнення про латч GPIO (розділ 1.3).

---

## 1. Головний результат

**Камера знайдена, жива і однозначно ідентифікована як IMX415.**

| Параметр | Значення |
|---|---|
| Фізичний порт | **CAM1** (конектор, який обслуговує `imx219-C` overlay) |
| I2C-шина | **i2c-9** (`i2c-2-mux chan_id 1`, батько — `cam_i2c` = `i2c@3180000` = i2c-2) |
| I2C-адреса | **0x37** — НЕ 0x1a, який припускав гайд! |
| Reset (XCLR) | пін **PAC.00** = DT gpio **160** на `gpio@2200000`, = **gpiochip0 line 138**, active-high release |
| Умова видимості на шині | сенсор ACK-ає лише при XCLR=1; див. нюанс латча у 1.3 |

### 1.1 Доказ ідентичності (читання регістрів при XCLR=1)

Всі значення = документованим power-on дефолтам IMX415 (звірено з guide §5.0):

| Регістр | Прочитано | Розшифровка |
|---|---|---|
| 0x3000 (MODE) | 0x01 | standby після power-on ✓ |
| 0x3002 (XMSTA) | 0x01 | stream stopped ✓ |
| 0x3024–26 (VMAX, LE) | ca 08 00 | VMAX = 0x08CA = **2250** — точний дефолт (2192+58) ✓ |
| 0x3028–29 (HMAX, LE) | 26 02 | HMAX = 0x0226 = 550 (power-on дефолт) |
| 0x3050–52 (SHR0, LE) | 66 00 00 | SHR0 = 0x66 = 102 |
| 0x4001 (LANEMODE) | 0x03 | 4-lane — заводський дефолт сенсора ✓ |

Команда відтворення (тримаючи reset високим у фоні):
```bash
gpioset --mode=time --sec=20 gpiochip0 138=1 &
i2ctransfer -y 9 w2@0x37 0x30 0x24 r3   # → 0xca 0x08 0x00
```

### 1.2 Адреса 0x37 — наслідки

- IMX415 має страп-селектор slave-адреси; на цьому модулі Waveshare застраплено **0x37**.
- **Незалежно підтверджено Фазою A** (RPi5, 2026-07-05, див. `rpi5_imx415_data.md`):
  probe `imx415 10-0037`, DT `reg = <0x37>`. Оверлей rpi-6.12.y використано **без**
  параметра `addr` — тобто 0x37 і є дефолт цього оверлея.
- **Фази D/E:** у DT-вузлі `reg = <0x37>;`, ім'я вузла `...@37`; у драйвері нічого
  міняти не треба (адреса приходить з DT).
- Усі місця гайду, де фігурує 0x1a (§2.3, §3.2, §6.2, §8.1 щабель 2 `<bus>-001a`) —
  читати як 0x37 / `9-0037`.

### 1.3 Нюанс: Tegra GPIO латчить останнє виставлене значення

Після виходу `gpioset` (libgpiod v1) пін **зберігає** останній записаний рівень —
лінія звільняється, але регістр не скидається. Тому після експериментів 2026-07-06
PAC.00 лишився високим, і 2026-07-07 сенсор ACK-ає на 0x37 вже і «без» gpioset.
Стан переживе до ребута або поки драйвер не пересмикне пін у probe. Висновок для
Фази G незмінний: у power_on() драйвера reset треба явно піднімати.

### 1.4 Повний скан з XCLR=1 (закрито 2026-07-07)

З утриманням reset високим прогнано **повний** діапазон 0x08–0x77 обох шин:
на i2c-9 — лише 0x37 (на модулі немає супутніх EEPROM/VCM/контролерів на I2C);
на i2c-10 (CAM0) — порожньо у всьому діапазоні.

---

## 2. Знімок стану target (guide §1.4)

| Параметр | Значення |
|---|---|
| L4T | **R36 (release), REVISION 5.0**, GCID 43688277, DATE 2026-01-16 (= JetPack 6.2.2) |
| KERNEL_VARIANT | oot |
| Ядро | **5.15.185-tegra** |
| OS | Ubuntu 22.04.5 LTS |
| Модель (DT) | NVIDIA Jetson Orin Nano Engineering Reference Developer Kit Super |
| Базовий DTB (FDT у extlinux) | `/boot/dtb/kernel_tegra234-p3768-0000+p3767-0005-nv-super.dtb` |
| rootfs | ext4 по `root=PARTUUID=40d4b2ef-…` — **LUKS немає** (примітка гайду §7.2 про LUKS2 не відповідає цій системі; копіювати APPEND точно все одно треба) |
| Тулзи на target | i2c-tools ✓, v4l-utils (`media-ctl`, `v4l2-ctl`) ✓, libgpiod (`gpioset`/`gpioinfo`) ✓, `dtc`/`fdtdump`/`fdtget` ✓ |
| Місце на диску | 49 ГБ вільно на / (NVMe, вистачає з запасом) |
| sudo | **потребує пароля** (агент не може виконувати root-команди сам) |
| dmesg/journal -k | недоступні без root (kernel.dmesg_restrict); журнал ядра порожній для adm |

### 2.1 extlinux.conf — поточний стан

- `DEFAULT UARTFix` — активний запис має:
  - `FDT /boot/dtb/kernel_tegra234-p3768-0000+p3767-0005-nv-super.dtb`
  - `OVERLAYS /boot/tegra234-p3767-camera-p3768-imx219-dual.dtbo,/boot/disable-uart1-dma.dtbo`
- Тобто **imx219-dual overlay вже застосований** (тому в системі живуть DT-вузли
  imx219 і завантажений модуль `nv_imx219`; probe сенсорів, очевидно, провалюється —
  фізичних IMX219 немає, `/dev/video*` відсутні, у media-графі nvcsi-entities без лінків).
- Запис `JetsonIO` — те саме без disable-uart1-dma. Запис `primary` — без FDT/OVERLAYS.
- **Для майбутнього запису `imx415` (§7.2):** копіювати запис `UARTFix`,
  у OVERLAYS **прибрати** `imx219-dual.dtbo` (щоб не конфліктували вузли на тих самих
  шинах/портах) і **лишити** `disable-uart1-dma.dtbo`, додавши наш
  `tegra234-p3767-camera-p3768-imx415.dtbo`.
- ⚠️ Бекап `extlinux.conf.bak-imx415` **ще не зроблено** (потрібен sudo):
  ```bash
  sudo cp /boot/extlinux/extlinux.conf /boot/extlinux/extlinux.conf.bak-imx415
  ```
  Старі бекапи існують (`.bak`, `.bak.20260427134315`, …), але вони старіші за поточний файл.

### 2.2 Розкладка модулів ядра (для Фази F)

- Всі OOT-модулі живуть у `/lib/modules/5.15.185-tegra/updates/…`
  (KERNEL_VARIANT=oot): `nv_imx219.ko` → `updates/drivers/media/i2c/nv_imx219.ko`.
- `nv_imx415.ko` логічно класти поруч: `updates/drivers/media/i2c/` + `depmod -a`.
- vermagic: `5.15.185-tegra SMP preempt mod_unload modversions aarch64`.

---

## 3. I2C smoke test (guide §3.2) — повний протокол

1. `i2cdetect -l`: камерні шини — це канали gpio-мультиплексора над i2c-2 (`cam_i2c`):
   - **i2c-10** = `i2c-2-mux (chan_id 0)` → конектор **CAM0**
   - **i2c-9** = `i2c-2-mux (chan_id 1)` → конектор **CAM1**
   - (грепати `i2cdetect -l` по слову "cam" марно — імена каналів `i2c-2-mux`)
2. Скан обох шин «як є»: порожньо (0x37 ще не видно — сенсор у reset).
3. Скан з утриманням XCLR (лінії 49 і 138 gpiochip0) високим:
   - i2c-10 (CAM0): порожньо — на CAM0 нічого не підключено.
   - i2c-9 (CAM1): **0x37**, стабільно у двох проходах.
4. Верифікація регістрами — розділ 1.1 вище.

Користувач `orca` у групах `i2c` та `gpio` — скани і gpioset працюють без root.

---

## 4. GPIO-карта камерних ліній (критично для Фаз D/E/G)

⚠️ **DT-номери GPIO ≠ офсети ліній gpiochip.** Перша спроба смикати «line 62/160»
(як у DT) влучила у PJ.04/PAG.04 — не ті піни. Правильний маппінг:

| Призначення | Пін | DT gpio (десятк.) | gpiochip0 line | Стан на момент збору |
|---|---|---|---|---|
| CAM0 reset (у imx219-оверлеї) | PH.06 | 62 (0x3e) | **49** | unused, output |
| CAM1 reset (у imx219-оверлеї) — **наша камера** | PAC.00 | 160 (0xa0) | **138** | unused, output |
| Хог базового DT `camera-control-output-low`, label `cam0-rst` | PH.03 | 59 (0x3b) | 46 | **hogged output-low** (зайнятий, з userspace не перемкнути) |
| Селектор i2c-мультиплексора | (phandle 0x105, gpio 0x13) | — | — | керується ядром |

- Флаг у `reset-gpios` = 0 → GPIO_ACTIVE_HIGH; «відпустити reset» = виставити 1.
- Хог PH.03 стосується лише CAM0-шляху; для нашої камери на CAM1 не заважає.

---

## 5. Живий donor-DT (з застосованого imx219-dual) — факти для Фази E

Шляхи вузлів (символи → шляхи):
- `imx219_cam0` → `/bus@0/cam_i2cmux/i2c@0/rbpcv2_imx219_a@10`
- `imx219_cam1` → `/bus@0/cam_i2cmux/i2c@1/rbpcv2_imx219_c@10` ← наш порт
- `cam_i2c` → `/bus@0/i2c@3180000`; мультиплексор — `/bus@0/cam_i2cmux` (`i2c-mux-gpio`)

Ключові факти:

| Факт | Значення | Наслідок |
|---|---|---|
| `tegra_sinterface` cam1 (наш порт) | **serial_c** | збігається з очікуванням гайду для донора `imx219-C` |
| `tegra_sinterface` cam0 | **serial_b** (не serial_a!) | якщо колись переставлятимемо камеру на CAM0 — звірити донора, не вірити припущенню «A → serial_a» |
| `clocks`/`clock-names`/`mclk` у вузлі сенсора | **відсутні взагалі** | закриває [ВЕРИФІКУВАТИ] з §6.2: вузол IMX415 теж не потребує clock-властивостей; `mclk_khz` у mode0 — суто інформаційна (у донора «24000») |
| num_lanes (mode0 cam1) | 2 | наш 2-lane план сумісний з портом |
| pixel_phase донора | rggb (imx219) | у нас буде gbrg — міняти |
| badge module1 | `jakku_rear_RBP194` | приклад формату badge для tegra-camera-platform |
| Донорські файли | `/boot/tegra234-p3767-camera-p3768-imx219-C.dtbo` існує у стоку | сорс-донор: `tegra234-p3767-camera-p3768-imx219-C.dts` |

Media-граф зараз: `tegra-camrtc-ca` / «NVIDIA Tegra Video Input Device», дві
nvcsi-entity **без лінків** і без сенсорів — очікувано, віддеокоди відсутні.

### 5.1 Донорський `imx219-C.dtbo` (розібрано 2026-07-07)

Декомпільований сорс збережено у **`reference/imx219-C-donor-decompiled.dts`**
(з `/boot/tegra234-p3767-camera-p3768-imx219-C.dtbo`, dtc на target). Ключове для Фази E:

| Факт | Значення | Наслідок для imx415-оверлея |
|---|---|---|
| `overlay-name` | "Camera IMX219-C" | своє ім'я, напр. "Camera IMX415-98" |
| `jetson-header-name` | **"Jetson 22pin CSI Connector"** | гайд §6.1 цитує "24pin" — фактично 22pin; не чіпати, як і радить гайд |
| `compatible` оверлея | список p3768-0000+p3767-000x(+super) | лишити як є |
| `tegra_sinterface` | serial_c у **всіх 5 mode** вузла c@10 | у нас один mode0 із serial_c |
| VI: `tegra-capture-vi` | num-channels=1; port@1, endpoint port-index=**2**, bus-width=**2** | port-index 2 = serial_c; лишити |
| NVCSI | num-channels=1; **channel@1**, port@0 endpoint@2 (port-index 2, bus-width 2) → port@1 endpoint@3 → VI | лишити топологію |
| Вузол a@10 (CAM0) | явно `status = "disabled"` | так само глушити невикористаний порт |
| reset-gpios c@10 | `<&gpio 0xa0 0x00>` = PAC.00, active-high | збігається з живим DT; лишити |
| tegra-camera-platform | **лише** `modules/module1` (badge `jakku_rear_RBP194`, position "rear", drivernode0 v4l2_sensor + drivernode1 v4l2_lens) | `num_csi_lanes`/`max_lane_speed`/`min_bits_per_pixel` з §6.3 гайду **відсутні** і в донорі, і в живому DT — не додавати; drivernode1 (lens) для imx415 прибрати або лишити фіктивним — вирішити у Фазі E |
| sysfs-device-tree | `/sys/firmware/devicetree/base/bus@0/cam_i2cmux/i2c@1/rbpcv2_imx219_c@10` | оновити під ім'я нашого вузла `...@37` |

---

## 6. Таблиця §10 гайду — заповнені рядки

Дані Фази A (RPi5, 2026-07-05) — у `rpi5_imx415_data.md`; тут зведення обох сторін.

| Параметр | Значення | Статус |
|---|---|---|
| L4T | R36.5.0 (GCID 43688277), ядро 5.15.185-tegra | ✅ |
| Кварц модуля | **37.125 МГц** (clk_summary на RPi5: `cam0_clk = 37125000` → inck) | ✅ |
| I2C-адреса | **0x37** (страп модуля; не 0x1a) — підтверджено на обох платформах | ✅ |
| Bayer-порядок | **GBRG** (`MEDIA_BUS_FMT_SGBRG10_1X10`), 10 біт | ✅ |
| Розміри кадру reference-драйвера | **3864×2192**, єдиний режим; **15 fps** @ 2-lane (не 30 — див. нижче) | ✅ |
| Порт на девкіті | **CAM1** | ✅ |
| Номер I2C-шини на Jetson | **9** (mux chan 1) | ✅ |
| Донорський overlay | `tegra234-p3767-camera-p3768-imx219-C.dts` | ✅ |
| tegra_sinterface | **serial_c** | ✅ |
| link_freq для INCK 37.125 | **445.5 МГц** (підтверджено контролом `link_frequency` на RPi) | ✅ |
| pix_clk_hz | 178 200 000; але `line_length` = **5280** і framerate **15 fps** (перерахунок у `rpi5_imx415_data.md` §2.3) | ✅ |
| fourcc формату на VI | **GB10** (`V4L2_PIX_FMT_SGBRG10`) для mode0; **GB12** (`V4L2_PIX_FMT_SGBRG12`) для mode1 (12-біт, з 2026-07-08). Виміряний layout у пам'яті (Фаза G): 16-біт контейнери, `raw16 = p<<6 \| p>>4` — розпакування `>>6` (GB10) / `>>4` (GB12), без паддінгу рядків | ✅ |
| Полярність IR-CUT | **день (фільтр IN) = PP.01 high (1), ніч = low (0)**; керування через FFC pin 18 (= `extperiph2_clk_pp1`, main GPIO лінія 113), без дротів — pinmux fragment@1 в оверлеї + `tools/ircut.sh`; лінія відпущена = керує фізичний перемикач. Валідовано на target 2026-07-11 (`phase_g_validation.md`) | ✅ |

### 6.1 Головні поправки до гайду з Фази A (деталі у `rpi5_imx415_data.md` §2)

1. **15 fps @ 2-lane, не 30.** 3864·2192·10·30 = 2.54 Гбіт/с > 1.782 Гбіт/с (2×891M).
   Reference-драйвер дає 15 fps (HMAX ≈ 2200, час рядка ≈ 29.63 мкс). Отже у DT:
   `max_framerate = 15000000`, `line_length = 5280`, `min_exp_time ≈ 119`,
   `max_exp_time ≈ 66430`; у frmfmt — 15 fps. 30 fps можливі лише на 4 лейнах.
2. **Регістри брати з гілки `rpi-6.12.y`** (не 6.6.y) — саме цей драйвер
   (srcversion D307833D7F402E825690CE0) валідовано з цим модулем.
3. **Reset/XCLR:** у RPi-оверлеї жодного reset-GPIO немає (лише регулятори), але
   на Jetson **емпірично** сенсор ACK-ає тільки при PAC.00=1 (розділ 3) — тобто
   пін конектора таки гейтить сенсор. Для Jetson: `reset-gpios` лишаємо (як у
   донора) і тримаємо високим після power-on.
4. Для перегляду еталонного `ref_raw.raw` з RPi: shift=6, stride 7744 байт
   (3872 uint16/рядок) — Додаток A гайду.

**Що лишилось поза Jetson:** ~~полярність IR-CUT~~ (закрито 2026-07-11 —
дріт не знадобився, керування виявилось на шлейфі, див. рядок вище);
бекап extlinux.conf під sudo. Далі — Фаза C (сорси/збірка) на x86-хості.
