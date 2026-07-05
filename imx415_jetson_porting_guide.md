# Портування Waveshare IMX415-98 IR-CUT на Jetson Orin Nano
## JetPack 6.2.2 (L4T R36.x) · Raw V4L2/Bayer пайплайн · Девкіт P3768

**Версія документа:** 1.2 (2026-07-05) — контрольна звірка: константи перевірено проти rpi-6.6.y `imx415.c`, nvidia-oot r36.5 (`nv_imx219.c`, `sensor_common.c`, `camera_common.h`, `imx219_mode_tbls.h`, `tegra-v4l2-camera.h`) та `L4TLauncher.c` (edk2-nvidia)
**Цільова конфігурація:** сирий Bayer через `/dev/videoN` (V4L2), без nvargus/ISP.
**Режим фази 1:** повний кадр 3864×2192 (нативний для reference-драйвера), 2-lane.
**Режим фази 2 (опційно):** binned 1080p — розділ 9.1.

---

## Умовні позначення

- `[ВЕРИФІКУВАТИ]` — факт, який я не можу гарантувати з пам'яті; поруч завжди є команда або документ для перевірки. Не пропускай ці позначки.
- `<...>` — плейсхолдер, який ти заповнюєш своїми значеннями.
- **host** — x86-воркстейшн (`nvidia@nvidia-workstation`, BSP у `~/nvidia/nvidia_sdk/JetPack_6.2.2_Linux_JETSON_ORIN_NANO_TARGETS/Linux_for_Tegra`).
- **target** — Jetson Orin Nano девкіт (`orca@tegra-ubuntu`).

---

## 0. Що ми будуємо і чому саме так

### 0.1 Чому немає простого шляху

Стоковий JetPack 6 має драйвери лише для IMX219 та IMX477. Waveshare IMX415-98
офіційно підтримується тільки на Raspberry Pi та Luckfox Omni3576 — драйвера під
Jetson від Waveshare не існує. Модуль працює на RPi5 завдяки драйверу
`drivers/media/i2c/imx415.c` у ядрі Raspberry Pi + libcamera. На Jetson цей драйвер
напряму не використати: downstream-стек NVIDIA (VI/NVCSI) вимагає сенсорний драйвер,
інтегрований у **tegracam framework**, і device tree зі специфічними для Tegra
властивостями режимів.

Отже, робота складається з двох артефактів:

1. **Kernel-драйвер `nv_imx415.c`** — out-of-tree модуль у дереві `nvidia-oot`.
   Glue-код (структура) береться з `nv_imx219.c`, регістрові таблиці та логіка
   контролів — з `imx415.c` ядра Raspberry Pi (саме проти нього Waveshare валідує
   цей модуль, і саме він гарантовано має конфігурацію для кварца 37.125 МГц).
2. **Device tree overlay** — описує сенсор на шині cam_i2c, граф
   sensor → NVCSI → VI та mode-таблицю.

### 0.2 Архітектура камерного стека Jetson (мінімум, який треба розуміти)

```
IMX415 ──MIPI CSI-2──> NVCSI (deserializer) ──> VI (video input) ──> /dev/videoN
  │                                                    │
  └──I2C (cam_i2c)── nv_imx415.c (tegracam subdev) ────┘  (media graph)
```

- **VI** створює V4L2 video-ноду і керує захопленням у пам'ять.
- **NVCSI** — приймач MIPI; його конфігурація (кількість лейнів, швидкість)
  береться з device tree.
- **tegracam framework** (`nvidia-oot/drivers/media/tegracam/…`) — обгортка NVIDIA
  над V4L2 subdev: реєструє сенсор, розбирає mode-таблиці з DT, надає стандартні
  контроли (gain/exposure/frame rate). Драйвер сенсора реалізує лише колбеки.
- Для **чистого V4L2** (наш випадок) ISP не задіюється взагалі: VI пише сирий
  Bayer у буфери. `nvarguscamerasrc`, tuning-файли, libargus — поза скоупом.

### 0.3 Ризики і запобіжники

| Ризик | Запобіжник |
|---|---|
| Помилковий DT overlay ламає завантаження | Overlay підключається окремим записом (`LABEL`) в `extlinux.conf`; дефолтний запис не чіпаємо. Серійна консоль дає вибір запису при завантаженні |
| Затирання робочого модуля/DT на target | Все ставимо у `/lib/modules/.../updates/` і окремі файли в `/boot`, нічого не перезаписуємо |
| Регістрові таблиці «з пам'яті»/з чужих постів | Єдине джерело регістрів — `imx415.c` з ядра RPi + datasheet Sony. Жодних значень із форумів без перевірки |
| Невірний INCK (24 vs 37.125 МГц) | Фаза A на RPi5 однозначно фіксує кварц конкретного екземпляра |

Ця робота не торкається фьюзів, UEFI, Secure Boot чи розділів — лише файли в
rootfs девкіта. На девелоперському (unfused) девкіті це повністю відновлюване.
Інтеграція підписаного модуля/DT у продакшн-пайплайн (initrd-flash, підписи) —
свідомо поза скоупом цього документа.

### 0.4 Оцінка трудомісткості

| Фаза | Час (реалістично) |
|---|---|
| A. Валідація на RPi5 | 0.5 дня |
| B. Електрика на Jetson | 0.5 дня |
| C. Сорси + чиста збірка | 0.5–1 день |
| D. Драйвер | 3–7 днів |
| E. Device tree | 1–2 дні |
| F–G. Деплой + налагодження | 2–5 днів (найбільш непередбачувана частина) |
| **Разом** | **1.5–3 тижні** |

---

## 1. Передумови

### 1.1 Обладнання

- Jetson Orin Nano девкіт (carrier P3768), NVMe-завантаження — як є.
- **Серійна консоль на девкіт** (USB-UART на дебаг-порт). Формально можна без неї,
  але при експериментах з DT це різниця між «обрав інший boot entry» і «перепрошив
  через recovery». Наполегливо рекомендую.
- Raspberry Pi 5 + картка з актуальною Raspberry Pi OS (Bookworm) — для Фази A.
- Камера Waveshare IMX415-98 IR-CUT + рідний 22-pin шлейф.
- x86-хост з уже розгорнутим BSP JetPack 6.2.2.

### 1.2 Пакети на host

```bash
sudo apt update
sudo apt install -y build-essential bc flex bison libssl-dev \
    device-tree-compiler kmod cpio rsync wget git
```

### 1.3 Документи, які тримати відкритими

1. **NVIDIA Jetson Linux Developer Guide → Camera Development → Sensor Software
   Driver Programming** (для своєї версії R36.x). Це первинне джерело щодо
   tegracam і властивостей DT. Усі спірні місця цього документа звіряй із ним.
2. **Jetson Orin Nano Developer Kit Carrier Board Specification (P3768)** — розводка
   CAM0/CAM1: кількість лейнів на порт, лінії reset/power для кожного конектора.
3. **Sony IMX415 datasheet / register map** (у публічному доступі є повні версії;
   потрібні розділи INCK settings, shutter/gain, readout modes).
4. RidgeRun wiki: *How to port a driver to JetPack 6* — гарний методичний
   конспект того ж процесу.
5. Ядро Raspberry Pi, файл `drivers/media/i2c/imx415.c` (гілка rpi-6.6.y або
   новіша) — джерело регістрів.

### 1.4 Знімок стану target до початку

```bash
# на target — зафіксувати точну версію L4T (потрібно у Фазі C):
cat /etc/nv_tegra_release
uname -r
# бекап конфігурації завантажувача:
sudo cp /boot/extlinux/extlinux.conf /boot/extlinux/extlinux.conf.bak-imx415
```

Запиши вивід `nv_tegra_release` у «паспорт проєкту» (розділ 10) — від нього
залежить тег сорсів.

---
## 2. Фаза A — валідація модуля на Raspberry Pi 5

Мета фази: підтвердити, що конкретний екземпляр камери справний, і зафіксувати
його «паспорт»: частоту кварца, I2C-адресу, формат/розміри кадру, порядок Bayer.
Це усуває цілий клас помилок на Jetson («драйвер не винен — модуль мертвий /
кварц не той»).

### 2.1 Підключення і конфігурація

1. Онови систему: `sudo apt update && sudo apt full-upgrade`.
2. Підключи камеру до порту CAM1 RPi5 (контакти шлейфа — за схемою з вікі
   Waveshare; шлейф «RPi5-стилю» 22-pin → 22-pin).
3. У `/boot/firmware/config.txt` додай (варіант для нового кварца, який Waveshare
   ставить на поточні партії):

```
camera_auto_detect=0
dtoverlay=imx415,clk-37125,cam1
```

Параметр `clk-37125` існує лише у свіжих ядрах RPi (у rpi-6.12.y є, у
rpi-6.6.y ще немає). Якщо dmesg лається на невідомий параметр оверлея —
еквівалентний явний запис:

```
dtoverlay=imx415,clock-frequency=37125000,link-frequency=445500000,cam1
```
(445.5 МГц — єдина link frequency, для якої у драйвері одночасно існують
параметри клокінгу під INCK 37.125 МГц і mode-таблиця; див. 5.0.)

4. Перезавантаж і перевір:

```bash
dmesg | grep -i imx415
rpicam-hello --list-cameras
rpicam-hello -t 5000        # 5 c прев'ю
```

### 2.2 Визначення кварца (критичний крок)

- Якщо з `clk-37125` камера детектиться і дає картинку → **кварц 37.125 МГц**.
- Якщо ні — прибери `clk-37125` (лишиться дефолт 24 МГц) і повтори. Якщо
  запрацювало → **кварц 24 МГц** (стара партія).
- Додатково звір з маркуванням кварца на платі (лупа/макрофото).

Запиши результат. Далі в документі я скрізь припускаю **37.125 МГц**; якщо у
тебе 24 МГц — у Фазі D бери з RPi-драйвера параметри для 24 МГц, решта кроків
ідентична.

### 2.3 Паспортні дані з RPi

```bash
# I2C-адреса і шина видно у рядку probe:
dmesg | grep -i imx415        # очікувано щось на кшталт "imx415 X-001a: ..."
                              # → адреса 0x1a [ВЕРИФІКУВАТИ на своєму виводі]

# Формати, які віддає драйвер (розмір, порядок Bayer, біти):
v4l2-ctl -d /dev/v4l-subdevX --list-subdev-mbus-codes 2>/dev/null || true
rpicam-hello --list-cameras   # покаже розміри і формат, напр. SGBRG10
```

Запиши: I2C-адресу, роздільність (очікувано 3864×2192), Bayer-порядок
(GBRG — звірено з кодом драйвера, `MEDIA_BUS_FMT_SGBRG10_1X10`; підтверди по
фактичному виводу), бітність (10).

### 2.4 Еталонні кадри

```bash
rpicam-still -o ref_day.jpg
rpicam-raw -t 1000 -o ref_raw.raw   # кілька сирих кадрів про запас
```

Збережи їх — при налагодженні на Jetson матимеш еталон того, як «має виглядати»
сенсор (рівень шуму, чутливість, кольори до/після IR-CUT).

### 2.5 Перевірка IR-CUT

На платі є пад GPIO для перемикання IR-CUT фільтра. З'єднай його дротом із GPIO
Raspberry Pi і перемкни рівень (див. вікі Waveshare) — фільтр має клацнути, а
картинка змінити колірний баланс. Зафіксуй: який логічний рівень = фільтр
увімкнено. Це знадобиться у розділі 9.2.

---

## 3. Фаза B — механіка та електрика на Jetson

### 3.1 Порт і шлейф

1. Вимкни девкіт і від'єднай живлення.
2. Підключи камеру до одного з 22-pin портів (CAM0/CAM1) на P3768.
   Орієнтація контактів шлейфа — за силкскріном/специфікацією carrier board
   (не «по пам'яті» з RPi: перевір, яким боком контакти в конекторі саме цього
   девкіта).
3. Для нашого 2-lane режиму придатні обидва порти. `[ВЕРИФІКУВАТИ]` у специфікації
   P3768: скільки лейнів розведено на кожен порт і які лінії reset/power їм
   призначені — ці ж дані підуть у device tree (розділ 6).

### 3.2 I2C smoke test

```bash
# на target
sudo apt install -y i2c-tools
i2cdetect -l | grep -i cam        # знайти номер шини cam_i2c [ВЕРИФІКУВАТИ номер]
sudo i2cdetect -y -r <bus>        # скан
```

Очікуваний результат: пристрій на **0x1a** (адреса, зафіксована у Фазі A).

**Якщо 0x1a не видно — це ще не вирок.** Можливі причини в порядку ймовірності:

1. Орієнтація/посадка шлейфа (найчастіше).
2. Інший порт — переткни в другий конектор і повтори скан на іншій шині.
3. Лінія reset (XCLR) сенсора на девкіті може за замовчуванням утримуватись
   у неактивному стані, поки драйвер не підніме GPIO. У такому разі сенсор
   не відповість на скан до появи драйвера — тоді остаточну перевірку
   електрики дасть лише probe драйвера у Фазі G. Не витрачай на це більше
   години: якщо шлейф перевірений з обох боків і на обох портах, рухайся далі.

Запиши у паспорт: порт (CAM0/CAM1), номер I2C-шини.

---

## 4. Фаза C — сорси, тулчейн, чиста збірка

### 4.1 Точна відповідність версій — головне правило

Модуль і DT мають збиратися з сорсів **точно тієї ж версії L4T**, що стоїть на
target. Верифікація:

```bash
# на target:
cat /etc/nv_tegra_release      # напр. "# R36 (release), REVISION: X.Y ..."
```

### 4.2 Отримання сорсів

Найдетермінованіший шлях — тарбол `public_sources.tbz2` **для твого точного
релізу** зі сторінки Jetson Linux (https://developer.nvidia.com/embedded/jetson-linux):

```bash
# на host
cd ~/nvidia/nvidia_sdk/JetPack_6.2.2_Linux_JETSON_ORIN_NANO_TARGETS/Linux_for_Tegra
# завантаж public_sources.tbz2 що відповідає R36.X.Y з /etc/nv_tegra_release
tar xf public_sources.tbz2 -C ..     # розпакує Linux_for_Tegra/source/
cd source
tar xf kernel_src.tbz2
tar xf kernel_oot_modules_src.tbz2
tar xf nvidia_kernel_display_driver_source.tbz2 2>/dev/null || true
```

Альтернатива — `./source_sync.sh -k -t <тег релізу>`: тег має відповідати твоєму
L4T; список тегів дивись у самому репозиторії (`git ls-remote --tags`), **не
вгадуй**.

Після розпакування у `Linux_for_Tegra/source/` мають бути щонайменше:
`kernel/` (дерево ядра), `nvidia-oot/` (out-of-tree модулі, тут житиме драйвер),
`hardware/` (device tree), `Makefile` (верхньорівневі цілі збірки).

### 4.3 Тулчейн

NVIDIA для R36 використовує aarch64-тулчейн Bootlin — посилання та точна версія
вказані у розділі *Kernel Customization* Developer Guide твого релізу. Розпакуй,
наприклад, у `~/l4t-toolchain` і налаштуй оточення:

```bash
export CROSS_COMPILE=~/l4t-toolchain/bin/aarch64-buildroot-linux-gnu-
export ARCH=arm64
```

### 4.4 Контрольна чиста збірка (до будь-яких змін!)

```bash
cd Linux_for_Tegra/source
export KERNEL_HEADERS=$PWD/kernel/kernel-jammy-src   # [ВЕРИФІКУВАТИ ім'я каталогу
                                                     #  дерева ядра у своєму релізі]
make modules -j"$(nproc)"    # OOT-модулі, включно з nvidia-oot
make dtbs                    # device tree, включно з camera overlays
```

Обидві цілі мають завершитись без помилок **до** того, як ти щось міняєш. Якщо
чиста збірка падає — розбирайся зараз (тулчейн, headers, версія), а не після
внесення свого коду, коли причин може бути вже дві. Типовий випадок: збірка
модулів скаржиться на неконфігуроване дерево ядра — тоді спершу `make -C kernel`
(або підготуй дерево через defconfig за розділом Kernel Customization).

Результати збірки dtbo: `kernel-devicetree/generic-dts/dtbs/` (підтверджено
для R36; за потреби `find . -name "*.dtbo" -newer Makefile` після `make dtbs`).

### 4.5 Джерело регістрів — ядро Raspberry Pi

```bash
cd ~/src
git clone --depth=1 --branch rpi-6.6.y https://github.com/raspberrypi/linux rpi-linux
less rpi-linux/drivers/media/i2c/imx415.c
```

Якщо на твоєму RPi5 стоїть новіше ядро (перевір `uname -r` на RPi) — клонуй
відповідну гілку `rpi-6.X.y`, щоб регістри збігалися з тим, що ти валідував
у Фазі A.

Додатково варто перевірити, чи не з'явився готовий IMX415-драйвер під
tegracam/JP6 у відкритих репозиторіях виробників сенсорних модулів (наприклад,
FRAMOS публікує драйвери своїх Jetson-модулів на GitHub, і в їхніх лінійках є
IMX415). Якщо знайдеться GPL-драйвер під R36 — він може заощадити більшу частину
Фази D: адаптувати чужий tegracam-глю простіше, ніж писати свій.
`[ВЕРИФІКУВАТИ]` наявність, версію L4T і ліцензію — я не можу гарантувати
актуальний стан цих репозиторіїв.

---
## 5. Фаза D — драйвер `nv_imx415.c`

### 5.0 Верифіковані константи (звірено з кодом, не з пам'яті)

Звірено безпосередньо з `drivers/media/i2c/imx415.c` гілки **rpi-6.6.y** —
перед використанням перевір, що у твоїй гілці значення ті самі:

| Параметр | Значення | Де у драйвері |
|---|---|---|
| Формат | `MEDIA_BUS_FMT_SGBRG10_1X10` → Bayer **GBRG**, 10 біт | enum_mbus_code |
| Кадр | 3864×2192, єдиний розмір у драйвері | `IMX415_PIXEL_ARRAY_*`, supported_modes |
| Lane rate для INCK 37.125 МГц | **891 Мбіт/с/лейн** (link freq 445.5 МГц) — єдина комбінація, де є і clk_params для 37.125, і mode-таблиця (720/1440 Мбіт/с для 37.125 відсутні) | `imx415_clk_params[]` + `supported_modes[]` |
| Регістрові масиви для перенесення | `imx415_init_table[]` + елемент `imx415_clk_params[]` (inck=37125000, lane_rate=891M) + `imx415_linkrate_891mbps[]` | там же |
| Лейни | `LANEMODE` 0x4001: значення 1 = 2-lane, 3 = 4-lane | `IMX415_LANEMODE` |
| Standby / стрім | 0x3000 (`MODE`: 0=operating, 1=standby), 0x3002 (`XMSTA`: 0=start, 1=stop) | `IMX415_MODE`, `IMX415_XMSTA` |
| Group hold | 0x3001 (`REGHOLD`: 1=hold, 0=apply) | `IMX415_REGHOLD` |
| VMAX | 0x3024, 24-біт; дефолт 2192+58(vblank) = **2250** | `IMX415_VMAX` |
| HMAX | 0x3028, 16-біт; для 2-lane@891M мінімум **1100**; час рядка = HMAX×12 / 891 МГц ≈ 14.8 мкс | `IMX415_HMAX`, `hmax_min` |
| Кадрова частота дефолтної конфігурації | 891e6 / (1100×12 × 2250) ≈ **30 fps** при 2-lane | розрахунок з рядка вище |
| Експозиція | `SHR0` 0x3050 (24-біт); інтеграція_ліній = VMAX − SHR0; offset 8; ctrl-діапазон 4…(VMAX−8) ліній | `IMX415_SHR0`, `IMX415_EXPOSURE_OFFSET` |
| Gain | 0x3090 (`GAIN_PCG_0`, 16-біт); діапазон **0…100** кроків × 0.3 дБ = 0…30 дБ | `IMX415_AGAIN_*` |
| regmap | reg 16 біт / val 8 біт | `imx415_regmap_config` |
| Регулятори у RPi-драйвері | dvdd, ovdd, avdd | `imx415_supply_names` |

Додатково звірено з фреймворком r36.5: **усі** властивості mode-вузла з
розділу 6.2 (pix_clk_hz, line_length, mode_type, pixel_phase,
csi_pixel_bit_depth, gain/exposure/framerate factors і межі,
embedded_metadata_height тощо) реально парсяться `sensor_common.c`;
структура `camera_common_frmfmt` = {size, framerates, num_framerates,
hdr_en, mode} — приклад у 5.3(10) їй відповідає.

І з `nvidia-oot/drivers/media/i2c/` гілки l4t-r36.5 (дзеркало OE4T/linux-nv-oot):
файли називаються **`nv_imx219.c`** і **`imx219_mode_tbls.h`**; compatible у
драйвері NVIDIA — `"sony,imx219"` (тобто конвенція `"sony,imx415"` для нашого —
правильна); структури ops збігаються з описаними у 5.3; Makefile збирає сенсори
через `obj-m` всередині `ifdef CONFIG_MEDIA_SUPPORT` і має
`subdir-ccflags-y += -Werror` — **будь-яке попередження компілятора у твоєму
файлі провалить збірку**, це очікувано.

### 5.1 Принцип роботи

Ми **не пишемо** V4L2-драйвер з нуля і **не портуємо** RPi-драйвер механічно.
Ми беремо два джерела і зшиваємо їх:

| Що | Звідки | Чому |
|---|---|---|
| Каркас (tegracam glue): probe, реєстрація, power, структури | `nvidia-oot/drivers/media/i2c/nv_imx219.c` + `imx219_mode_tbls.h` (імена звірено для r36.5) | Це еталон того, як сенсор інтегрується у стек NVIDIA саме цієї версії L4T |
| Регістри: init-послідовність, параметри PLL для INCK=37.125 МГц, mode-таблиця, адреси регістрів GAIN/SHR0/VMAX | `rpi-linux/drivers/media/i2c/imx415.c` | Єдина перевірена конфігурація саме для цього модуля з цим кварцом |
| Семантика і межі контролів | Datasheet Sony IMX415 | Первинне джерело; RPi-драйвер — робочий приклад його трактування |

**Правило: жодного регістрового значення, якого немає у RPi-драйвері або
datasheet.** Значення з форумів/чатів — тільки як підказка, де шукати у
первинних джерелах.

### 5.2 Створення файлів

```bash
cd Linux_for_Tegra/source/nvidia-oot/drivers/media/i2c
cp nv_imx219.c nv_imx415.c
# якщо mode-таблиці imx219 винесені в окремий header — скопіюй і його:
cp imx219_mode_tbls.h imx415_mode_tbls.h   # ім'я звірено для r36.5
```

Глобальна заміна символів: `imx219` → `imx415`, `IMX219` → `IMX415` в обох
файлах (потім усе одно пройтись руками).

Інтеграція у збірку — у `Makefile` цього ж каталогу додай поряд з imx219:

```makefile
obj-m += nv_imx415.o
```

Додавай його **всередині** блоку `ifdef CONFIG_MEDIA_SUPPORT`, поряд з
`obj-m += nv_imx219.o` (структура Makefile r36.5 перевірена). Пам'ятай про
`-Werror` (див. 5.0).

### 5.3 Анатомія драйвера: що саме міняти

Нижче — мапа файла у порядку, в якому його варто проходити. Імена структур —
з imx219-драйвера ери JP6; у твоєму релізі можуть трохи відрізнятись —
орієнтуйся на реальний код, а не на цей список.

```
nv_imx415.c
├── #include "imx415_mode_tbls.h"
├── визначення регістрів керування ──────────────── (1)
├── static const struct of_device_id imx415_of_match[]
│      .compatible = "sony,imx415"  ──────────────── (2)
├── struct imx415 { ... }            — приватний стан, майже без змін
├── static const struct regmap_config — 16-біт адреса / 8-біт дані:
│      .reg_bits = 16, .val_bits = 8  (у IMX415 так само, як у IMX219)
├── imx415_set_group_hold()          ──────────────── (3)
├── imx415_set_gain()                ──────────────── (4)
├── imx415_set_exposure()            ──────────────── (4)
├── imx415_set_frame_rate()          ──────────────── (4)
├── static struct tegracam_ctrl_ops imx415_ctrl_ops
│      { .set_gain, .set_exposure, .set_frame_rate, .set_group_hold, ... }
├── imx415_power_on() / imx415_power_off()  ───────── (5)
├── imx415_power_get() / _put(), imx415_parse_dt()  — майже без змін
├── imx415_set_mode()                ──────────────── (6)
├── imx415_start_streaming() / imx415_stop_streaming() ─ (7)
├── static struct camera_common_sensor_ops imx415_common_ops
│      { .numfrmfmts, .frmfmt_table, .power_on/off, .set_mode,
│        .start/stop_streaming, .parse_dt, ... }
└── imx415_probe()                   ──────────────── (8)

imx415_mode_tbls.h
├── масиви регістрів: init + mode(и) + start/stop stream ─ (9)
└── static const struct camera_common_frmfmt imx415_frmfmt[] ─ (10)
```

**(1) Регістри керування.** З RPi-драйвера/datasheet винеси адреси:
standby/streaming, group hold (register hold), GAIN, SHR0, VMAX, HMAX.
Не переноси «за звичкою» адреси від imx219 — у IMX415 своя карта регістрів.

**(2) Compatible-рядок.** `"sony,imx415"` — і точно такий самий рядок має бути
у device tree (розділ 6). Це найчастіша «дурна» причина того, що probe взагалі
не викликається.

**(3) Group hold.** Register-hold біт для атомарної зміни gain/exposure:
`REGHOLD` 0x3001 (1 = тримати, 0 = застосувати) — див. 5.0. Реалізація
тривіальна: запис 1 на вході, 0 на виході.

**(4) Контроли — найбільша змістовна робота.**
Семантика IMX415 (звірено з RPi-драйвером, див. 5.0):

- *Експозиція*: `SHR0 = VMAX − інтеграція_в_лініях` — щоб **збільшити**
  експозицію, SHR0 **зменшується**. Діапазон інтеграції: 4…(VMAX−8) ліній.
  Час однієї лінії за замовчуванням ≈ 14.8 мкс.
- *Frame rate*: через VMAX; `fps = 891e6 / (HMAX×12 × VMAX)` для
  37.125 МГц-конфігурації (перевір формулу, якщо міняєш HMAX).
- *Gain*: регістр 0x3090, значення 0–100 у кроках 0.3 дБ (0–30 дБ). Вище
  30 дБ reference-драйвер не ходить — не ходи і ти, поки не звіриш HCG-режими
  з datasheet.

tegracam передає у ці колбеки значення у фіксованому масштабі, який задається
властивостями DT (`gain_factor`, `exposure_factor`, `framerate_factor`,
`min/max_gain_val` тощо — розділ 6.3). Твоє завдання у колбеках — конвертувати
це значення у регістрове за формулами datasheet. Подивись, як точно це зроблено
в imx219-драйвері (він конвертує так само, тільки формули інші).

**(5) Power on/off.** Послідовність: увімкнути регулятори (на 22-pin модулі
живлення береться з конектора, тож у DT це фіктивні fixed-regulators за
аналогією з imx219) → відпустити reset GPIO (XCLR у високий рівень) → пауза
за datasheet (одиниці мс) → сенсор готовий до I2C. Reset GPIO прийде з DT
(`reset-gpios`) — сам пін залежить від порту CAM0/CAM1 (розділ 6.2).

**(6) set_mode.** Записує у сенсор плоску послідовність: `imx415_init_table[]`
+ регістри з елемента `imx415_clk_params[]` для (inck=37125000,
lane_rate=891000000) + `imx415_linkrate_891mbps[]` + `LANEMODE=1` (2-lane).
Це і є «розгортання» конфігурації RPi-драйвера у tegracam-таблицю. Link
frequency цієї комбінації — 445.5 МГц (5.0) — використовується у розрахунку
`pix_clk_hz` (6.2).

**(7) start/stop_streaming.** Запис у standby/stream-регістр (значення з
RPi-драйвера). Часто це той самий регістр 0x3000-діапазону standby + окремий
XMSTA — точні адреси з datasheet/RPi-драйвера, не з пам'яті.

**(8) probe.** Каркас лишається від imx219: `tegracam_device_register` →
заповнення ops → `tegracam_v4l2subdev_register`. Заміни лише імена, розміри
структур і рядок сенсора.

**(9) Регістрові масиви.** Формат масивів залиш той, що у `*_mode_tbls.h`
imx219 (пара «адреса-значення» + маркер кінця таблиці). Вміст:

- `imx415_init_common[]` — глобальна ініціалізація з RPi-драйвера
  (все, що він пише незалежно від режиму) + гілка INCK=37.125 МГц.
- `imx415_mode_3864x2192[]` — параметри повного кадру (розміри, лейни,
  формат RAW10, HMAX/VMAX за замовчуванням).
- `imx415_start[]` / `imx415_stop[]` — вихід/вхід у standby.

Увага до **лейнів**: RPi-конфігурація за замовчуванням — 2-lane; саме її і
беремо (наша ціль 1080p, 2 лейнів вистачає з великим запасом, а конфігурація
максимально відповідає перевіреній у Фазі A).

Увага до **багатобайтових регістрів**: формат таблиць tegracam — `struct reg_8`
(один байт на запис), а RPi-драйвер пише VMAX/SHR0 (24-біт), GAIN/HMAX (16-біт)
одним логічним записом. Розкладай побайтово **little-endian** — молодший байт
за молодшою адресою (звірено з `imx415_write()`:
`data[3] = {val & 0xff, val>>8 & 0xff, val>>16}`). Приклад: VMAX = 2250 =
0x0008CA → `{0x3024, 0xCA}, {0x3025, 0x08}, {0x3026, 0x00}`. Для пауз у
таблицях є маркер `IMX415_TABLE_WAIT_MS` (за зразком imx219).

**(10) frmfmt-таблиця.**

```c
static const int imx415_30fps[] = { 30 };
static const struct camera_common_frmfmt imx415_frmfmt[] = {
    { {3864, 2192}, imx415_30fps, 1, 0, IMX415_MODE_3864x2192 },
};
```

Дефолтна 2-lane конфігурація при 891 Мбіт/с дає ≈30 fps (розрахунок у 5.0) —
30 у frmfmt коректно. Головне — консистентність із max_framerate у DT.

### 5.4 Збірка модуля

```bash
cd Linux_for_Tegra/source
make modules -j"$(nproc)" 2>&1 | tee /tmp/build_imx415.log
find . -name "nv_imx415.ko"
```

Ітеруй до чистої збірки. Попередження компілятора у своєму файлі не ігноруй —
у kernel-коді вони майже завжди означають реальну помилку.

---
## 6. Фаза E — Device Tree

### 6.1 Стратегія: адаптувати, не писати з нуля

У `Linux_for_Tegra/source/hardware/nvidia/t23x/nv-public/overlay/` лежать готові
камерні оверлеї девкіта (`ls` покаже файли на кшталт
`tegra234-p3767-camera-p3768-imx219-*.dts` — точні імена дивись у своєму релізі).
Роби так:

```bash
cd Linux_for_Tegra/source/hardware/nvidia/t23x/nv-public/overlay
ls *camera*p3768*
# донор одинарного порту (перевірені стокові імена):
#   tegra234-p3767-camera-p3768-imx219-A.dts  → порт CAM0 (serial_a)
#   tegra234-p3767-camera-p3768-imx219-C.dts  → порт CAM1 (serial_c)
cp tegra234-p3767-camera-p3768-imx219-<A|C>.dts \
   tegra234-p3767-camera-p3768-imx415.dts
```

Вибери за основу imx219-оверлей **того самого порту**, куди фізично підключена
камера (одинарний, не dual). З нього успадковуються правильні: I2C-шина,
reset-GPIO лінія конектора, tegra_sinterface (A → serial_a, C → serial_c) і
зв'язки портів sensor→NVCSI→VI — замість вгадування ти міняєш лише сенсорну
частину у файлі, де топологія порту вже правильна. Шапку оверлея
(`jetson-header-name = "Jetson 24pin CSI Connector"`,
`compatible = JETSON_COMPATIBLE_P3768`) не чіпай — завдяки їй оверлей видно
і в jetson-io.

Додай новий файл у список збірки оверлеїв (Makefile поряд, за аналогією з
існуючими записами) і онови у самому файлі `overlay-name` на щось своє,
наприклад `"Camera IMX415-98"`.

### 6.2 Що міняється у вузлі сенсора

У скопійованому файлі знайди вузол `imx219@10` (або подібний) на камерній
I2C-шині і перетвори на:

```dts
imx415_cam0: rbpcv415_a@1a {
    compatible = "sony,imx415";        /* = compatible у драйвері! */
    reg = <0x1a>;                      /* адреса з Фаз A/B */

    /* лінії reset/power НЕ чіпай — вони успадковані від imx219-оверлея
       і відповідають конектору. Перейменуй лише мітки за смаком. */

    /* клок: на платі власний кварц 37.125 МГц; властивості клоку,
       успадковані від imx219 (mclk від Tegra), для нашого модуля
       фактично не використовуються сенсором. Залиш як є, але у
       властивості mclk_khz нижче вкажи реальні 37125 — вона
       інформаційна для фреймворку. [ВЕРИФІКУВАТИ]: якщо probe
       скаржиться на clocks — залиш повністю конфіг imx219. */

    mode0 {
        mclk_khz = "37125";
        num_lanes = "2";
        tegra_sinterface = "serial_a"; /* НЕ міняй відносно донора-порту */
        phy_mode = "DPHY";
        discontinuous_clk = "no";      /* [ВЕРИФІКУВАТИ] по RPi-конфігу:
                                          continuous clock => "no" */
        dpcm_enable = "false";
        cil_settletime = "0";

        active_w = "3864";
        active_h = "2192";
        mode_type = "bayer";
        pixel_phase = "gbrg";          /* Bayer-порядок з Фази A(2.3) */
        csi_pixel_bit_depth = "10";
        readout_orientation = "0";

        line_length = "2640";          /* стартове значення, виведення нижче */
        pix_clk_hz = "178200000";      /* 891e6 × 2 лейни / 10 біт, див. нижче */
        /* serdes_pix_clk_hz НЕ додавати — властивість лише для SerDes */

        gain_factor = "1000";
        min_gain_val = "0";            /* 0–30 дБ: діапазон reference-       */
        max_gain_val = "30000";        /* драйвера (0–100 кроків × 0.3 дБ),  */
        step_gain_val = "300";         /* див. 5.0                            */
        default_gain = "0";

        exposure_factor = "1000000";
        min_exp_time = "59";           /* ≈4 лінії × 14.8 мкс */
        max_exp_time = "33200";        /* ≈(2250−8) ліній × 14.8 мкс */
        step_exp_time = "1";
        default_exp_time = "10000";

        framerate_factor = "1000000";
        min_framerate = "2000000";
        max_framerate = "30000000";    /* 30 fps дефолтної конфігурації */
        step_framerate = "1";
        default_framerate = "30000000";

        embedded_metadata_height = "0"; /* якщо у Фазі G буде
                                           CHANSEL_NOMATCH — перше, що
                                           перевіряти (розділ 8.4) */
        inherent_gain = "1";
    };

    ports {  /* endpoint-граф успадковано від донора; перевір лише
                num_lanes у endpoint, якщо він там дублюється */ };
};
```

**Розрахунок `pix_clk_hz`.** Для сирого захоплення це головна «пропускна»
властивість — з неї VI рахує таймаути і смугу:

```
pix_clk_hz = link_freq × 2 (DDR) × num_lanes / біти_на_піксель
```

Для нашої конфігурації (звірено, 5.0): link_freq 445.5 МГц, 2 лейни, RAW10 →
445.5e6 × 2 × 2 / 10 = **178 200 000**. Занижений pix_clk_hz дає таймаути VI
на рівному місці; кращий бік помилки — трохи завищити.

**line_length** використовується tegracam лише для перерахунку
exposure/framerate (на захоплення не впливає). Стартове значення виводиться
з умови консистентності: `fps = pix_clk_hz / (line_length × VMAX)` →
178.2e6 / (LL × 2250) = 30 → **LL ≈ 2640**. Якщо виміряний fps або
поведінка exposure-контролу не зійдуться — коригуй саме цю властивість.

### 6.3 tegra-camera-platform

У донорському оверлеї вже є вузол `tegra-camera-platform` з `modules`. Заміни
у ньому badge/ім'я драйвера:

```dts
tegra-camera-platform {
    num_csi_lanes = <2>;
    max_lane_speed = <1500000>;       /* кбіт/с на лейн; >= фактичного */
    min_bits_per_pixel = <10>;
    ...
    modules {
        module0 {
            badge = "imx415_cam0";
            position = "front";
            orientation = "1";
            drivernode0 {
                pcl_id = "v4l2_sensor";
                sysfs-device-tree = "/sys/firmware/devicetree/base/...";
                /* шлях скоригуй під фактичне ім'я вузла сенсора;
                   у JP6 властивість називається sysfs-device-tree
                   (у JP4/5 була proc-device-tree) — звір з донором */
            };
        };
    };
};
```

### 6.4 Збірка і перевірка dtbo

```bash
cd Linux_for_Tegra/source
make dtbs
find . -name "*imx415*.dtbo"
# статична перевірка вмісту:
fdtdump <шлях>/tegra234-p3767-camera-p3768-imx415.dtbo | less
```

У fdtdump переконайся: адреса 0x1a, compatible = "sony,imx415", num_lanes = 2,
всі `<...>` плейсхолдери заповнені.

---

## 7. Фаза F — деплой на target

Ядро ми не міняли — переносяться лише **модуль** і **dtbo**.

### 7.1 Модуль

```bash
# host → target
scp nvidia-oot/drivers/media/i2c/nv_imx415.ko orca@tegra-ubuntu:/tmp/

# на target:
sudo mkdir -p /lib/modules/$(uname -r)/updates
sudo cp /tmp/nv_imx415.ko /lib/modules/$(uname -r)/updates/
sudo depmod -a
```

Модуль прив'язаний до конкретної версії ядра: після будь-якого оновлення
`nvidia-l4t-kernel` через apt його треба перезібрати з сорсів відповідної
версії і покласти заново.

### 7.2 Overlay — окремим boot-записом

```bash
# host → target
scp <шлях>/tegra234-p3767-camera-p3768-imx415.dtbo orca@tegra-ubuntu:/tmp/
# на target:
sudo cp /tmp/tegra234-p3767-camera-p3768-imx415.dtbo /boot/
```

У `/boot/extlinux/extlinux.conf` **не чіпаючи** запис `primary`, додай копію
запису з overlay:

```
LABEL imx415
      MENU LABEL primary + IMX415 overlay
      LINUX /boot/Image
      FDT /boot/dtb/<той самий dtb, що у primary>
      INITRD /boot/initrd
      OVERLAYS /boot/tegra234-p3767-camera-p3768-imx415.dtbo
      APPEND <скопіюй рядок APPEND з primary без змін>
```

Ключове слово `OVERLAYS` парситься завантажувачем L4T нарівні з
LABEL/LINUX/FDT/INITRD/APPEND (звірено з `L4TLauncher.c` в edk2-nvidia).
Якщо у твоєму `primary` вже є рядок `OVERLAYS` — додай свій dtbo через кому
в кінці списку у **новому** записі. Завантаження у цей запис — через меню на
серійній консолі (або тимчасово `DEFAULT imx415`, коли впевнишся, що воно
живе). Диск у тебе LUKS2 — записи копіюй точно, включно з усім `APPEND`,
інакше rootfs не змонтується.

### 7.3 Перше завантаження

```bash
sudo reboot
# після завантаження у запис imx415:
sudo modprobe nv_imx415
dmesg | grep -iE "imx415|tegracam"
```

Очікуваний успіх: рядки probe без помилок і поява `/dev/video0`
(`ls /dev/video*`). Якщо модуль хочеш вантажити автоматично — після успішної
валідації додай `nv_imx415` у `/etc/modules-load.d/imx415.conf`.

---
## 8. Фаза G — валідація і налагодження

### 8.1 Драбина перевірок (знизу вгору)

Кожен щабель ізолює свій шар. Не перескакуй: «не працює v4l2-ctl» без
пройдених нижніх щаблів — це чотири різні проблеми, які виглядають однаково.

**Щабель 1 — I2C/probe:**
```bash
dmesg | grep -i imx415
```
Probe пройшов → драйвер знайшов сенсор за I2C, power-on послідовність і
reset працюють. Помилки тут = електрика/адреса/compatible/power_on.

**Щабель 2 — топологія media graph:**
```bash
sudo apt install -y v4l-utils
media-ctl -p -d /dev/media0
```
Має бути ланцюжок: `imx415 <bus>-001a` → `nvcsi` → `vi`. Немає сенсора у
графі → DT: endpoint-зв'язки/tegra-camera-platform.

**Щабель 3 — формати:**
```bash
v4l2-ctl -d /dev/video0 --list-formats-ext
```
Очікуємо 10-бітний Bayer 3864×2192. Fourcc залежить від pixel_phase у DT
(наприклад `GB10` для GBRG — але не вгадуй, команда сама покаже фактичний).

**Щабель 4 — контроли:**
```bash
v4l2-ctl -d /dev/video0 -L
v4l2-ctl -d /dev/video0 -c gain=100
v4l2-ctl -d /dev/video0 -c exposure=5000
```
Помилки I2C у dmesg при зміні контролів → адреси регістрів у колбеках (5.3.4).

**Щабель 5 — захоплення (головний тест):**
```bash
v4l2-ctl -d /dev/video0 \
  --set-fmt-video=width=3864,height=2192,pixelformat=<fourcc_зі_щабля_3> \
  --set-ctrl bypass_mode=0 \
  --stream-mmap --stream-count=100 --stream-to=/tmp/cap.raw --verbose
```
`bypass_mode=0` — важливо: без нього канал може очікувати керування зі
сторони ISP-стека, якого у нас немає (контрол `TEGRA_CAMERA_CID_VI_BYPASS_MODE`
існує в r36.5 — звірено). `--verbose` друкує `<` на кожен кадр —
одразу видно фактичний fps.

**Щабель 6 — вміст кадру:** скрипт з Додатку C. Дивимося не «чи є байти», а
чи це схожий на сцену Bayer: реагує на закривання об'єктива рукою, на зміну
exposure, немає зсуву рядків.

**Щабель 7 — стабільність:** стрім на 10+ хвилин
(`--stream-count=20000`), перевірити відсутність деградації fps і помилок
у dmesg.

### 8.2 Низькорівневе трасування VI/CSI

Коли probe успішний, а кадрів немає — вмикай трасування камерного firmware
(RTCPU). Точні шляхи звір з розділом камерного дебагу Developer Guide свого
релізу; типовий рецепт `[ВЕРИФІКУВАТИ]`:

```bash
cd /sys/kernel/debug/tracing
echo 1 > tracing_on
echo 30720 > buffer_size_kb
echo 1 > events/tegra_rtcpu/enable
# ...запустити захоплення в іншому терміналі...
cat trace | tail -200
```

У трасі шукай повідомлення CHANSEL/PXL з розшифровками помилок нижче.

### 8.3 Таблиця типових відмов

| Симптом | Найімовірніша причина | Куди дивитись |
|---|---|---|
| probe не викликається взагалі (тиша у dmesg) | compatible у DT ≠ compatible у драйвері; overlay не застосувався | `cat /proc/device-tree/...` — чи є вузол сенсора; звір рядки |
| probe: I2C NACK / read failed | адреса; шлейф; reset-GPIO не той/не та полярність; замала пауза після reset | Фаза B; порівняй reset-лінію з донорським imx219-оверлеєм |
| probe OK, немає /dev/video0 | tegra-camera-platform: badge/drivernode/sysfs-шлях | fdtdump dtbo; донорський вузол |
| Захоплення: timeout, 0 кадрів, `PXL_SOF` timeout у трасі | сенсор не стрімить (start_streaming регістри) АБО lane/швидкість: num_lanes у DT ≠ конфігу сенсора, занижений pix_clk_hz, невірний tegra_sinterface | 5.3.7; перерахуй 6.2; звір sinterface з донором |
| `CHANSEL_NOMATCH` у трасі | формат/розмір із DT ≠ фактичному потоку: embedded_metadata_height, pixel_phase, active_w/h | почни з embedded_metadata_height (спробуй значення з datasheet щодо embedded lines) |
| `CHANSEL_SHORT_FRAME` / рвані кадри | розміри у DT ≠ регістровій конфігурації; проблемний шлейф | звір mode-таблицю (5.3.9) з active_w/h |
| Кадри є, зображення «зелене сміття» | нормально для сирого Bayer у звичайному переглядачі! Дивись через Додаток C | — |
| Зображення є, але зсунуте/смуги | невірний stride/упаковка при перегляді, не в захопленні | параметр shift у скрипті Додатку C |
| Періодичні пропуски кадрів | pix_clk_hz на межі; шлейф | збільш pix_clk_hz; коротший шлейф |

### 8.4 Незалежна перевірка «сенсор взагалі стрімить»

Якщо застряг між «probe OK» і «кадрів немає», відв'яжи гіпотези: додай у
`imx415_start_streaming()` тимчасове читання регістра стану сенсора після
старту (потоковий стан/лічильник кадрів — подивись у datasheet, які
status-регістри доступні). Сенсор каже «стрімлю», а VI кадрів не бачить →
проблема на стороні CSI-конфігурації (лейни/швидкість/sinterface), а не
регістрів сенсора. Це заощаджує дні.

---

## 9. Фаза H — після базового успіху

### 9.1 Режим 1080p

Reference-драйвер RPi, найімовірніше, має лише повний кадр 3864×2192
`[ВЕРИФІКУВАТИ по list-formats на RPi у Фазі A]`. Твої опції у порядку
зростання складності:

1. **Нічого не робити з сенсором.** 3864×2192 RAW10 @ 30 fps ≈ 500 МБ/с — Orin це перетравлює; кроп/скейл до 1080p роби у своєму
   пайплайні (CUDA-дебаєр все одно писати). Рекомендую почати так.
2. **Кроп на сенсорі** (window cropping IMX415): менше даних з CSI, вища
   частота кадрів. Регістри вікна — datasheet.
3. **Binned 1932×1096**: окремий mode у драйвері+DT. Джерела регістрових
   таблиць binned-режиму: datasheet (розділ readout modes) і GPL-драйвери
   інших платформ, де IMX415 має кілька режимів (наприклад, Rockchip BSP —
   Luckfox підтримує цей самий модуль). Додаєш `imx415_mode_1932x1096[]`,
   другий `mode1` у DT і другий рядок у frmfmt — механіка та сама.

### 9.2 IR-CUT

Фільтр керується окремим падом на платі (Фаза A, 2.5) — до CSI/драйвера він
не має стосунку. На Jetson заведи пад на вільний GPIO 40-pin header'а:

```bash
sudo apt install -y gpiod
gpioinfo                      # знайти chip/line для обраного піна
gpioset <chip> <line>=1       # перемкнути фільтр (полярність — з Фази A 2.5)
```

Рівні 3.3В — сумісні напряму. У продукті це стане одним рядком через libgpiod
у твоєму сервісі.

### 9.3 Другий модуль / другий порт

Додається другий вузол сенсора на I2C-шині другого порту + module1 у
tegra-camera-platform + другий екземпляр у frmfmt-логіці не потрібен (драйвер
один, інстансів два). Найпростіше — взяти за донора dual-imx219 оверлей і
повторити розділ 6 для нього.

### 9.4 Дорога у продакшн (за межами цього документа)

Для прод-юнітів з UEFI Secure Boot і підписаним ланцюжком: OOT-модуль і dtbo
мають потрапляти у підписані артефакти твого initrd-flash пайплайна, а не
копіюватись у /boot руками. Плануй це як окрему задачу інтеграції golden
master; чинна інструкція валідна для девелоперського девкіта.

---

## 10. Паспорт проєкту (заповнюй по ходу)

| Параметр | Значення | Фаза |
|---|---|---|
| L4T (`nv_tegra_release`) | | 1.4 |
| Кварц модуля | 37.125 МГц / 24 МГц | 2.2 |
| I2C-адреса | 0x1a (підтвердити) | 2.3 |
| Bayer-порядок | | 2.3 |
| Розміри кадру reference-драйвера | | 2.3 |
| Порт на девкіті | CAM0 / CAM1 | 3.2 |
| Номер I2C-шини на Jetson | | 3.2 |
| Донорський overlay-файл | | 6.1 |
| tegra_sinterface | | 6.1 |
| link_freq для INCK 37.125 | | 5.3.6 |
| pix_clk_hz (розрахунок) | | 6.2 |
| fourcc формату на VI | | 8.1 |
| Полярність IR-CUT | | 2.5 |

Фінальний чекліст готовності Фази 1:
- [ ] 100 кадрів підряд без помилок у dmesg
- [ ] Кадр реагує на gain/exposure контроли
- [ ] Стрім 10 хв без деградації
- [ ] Зображення співставне з еталоном RPi (шум/чутливість)
- [ ] Все відтворюється з чистого ребута (modules-load.d + OVERLAYS)

---

## Додаток A. Мінімальний перегляд RAW10 з VI

VI пише 10-бітні відліки у 16-бітні комірки; вирівнювання (LSB/MSB) залежить
від конфігурації — тому у скрипті параметр shift, перебери 0..6:

```python
#!/usr/bin/env python3
# usage: python3 raw_view.py cap.raw 3864 2192 [shift] [frame_idx]
import sys, numpy as np
import matplotlib.pyplot as plt

path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
shift = int(sys.argv[4]) if len(sys.argv) > 4 else 0
idx   = int(sys.argv[5]) if len(sys.argv) > 5 else 0

frame_px = w * h
raw = np.fromfile(path, dtype=np.uint16,
                  count=frame_px, offset=idx * frame_px * 2)
img = (raw.reshape(h, w) >> shift).astype(np.float32)
img /= max(img.max(), 1)

# грубий "дебаєр" середнім по 2x2 — досить, щоб побачити сцену
lum = (img[0::2,0::2] + img[1::2,0::2] + img[0::2,1::2] + img[1::2,1::2]) / 4
plt.imshow(lum, cmap="gray"); plt.title(f"shift={shift}")
plt.show()
```

Правильний shift — той, де гістограма не «прибита» до нуля/максимуму і сцена
виглядає природно. Якщо ширина буфера не збігається (смуги по діагоналі) —
у VI може бути падінг рядка (stride > width); фактичний stride дивись у
`--verbose` виводі v4l2-ctl і підстав як ширину.

## Додаток B. Джерела

1. NVIDIA Jetson Linux Developer Guide (свій R36.x): Camera Development →
   Sensor Software Driver Programming; Kernel Customization.
2. Jetson Orin Nano Developer Kit Carrier Board Specification (P3768).
3. Sony IMX415 datasheet / register map.
4. Ядро Raspberry Pi: `drivers/media/i2c/imx415.c` (гілка свого ядра RPi).
5. Waveshare wiki: IMX415-98 IR-CUT Camera.
6. RidgeRun wiki: How to port a driver to JetPack 6.
7. Тред Raspberry Pi Forums про imx415-модулі Waveshare (24 vs 37.125 МГц,
   4lane) — контекст, не джерело регістрів.
8. NVIDIA Developer Forums — теги imx415/orin nano: чужі граблі з PXL_SOF і
   CHANSEL корисно читати із увімкненим критичним мисленням.

## Додаток C. Правила гігієни цього порту

1. Комітити (git) сорсовий стан після кожного робочого щабля з 8.1.
2. Жодних правок у `bootloader/` і жодного перепрошивання — цей порт живе
   повністю у rootfs.
3. Кожне значення, взяте з форуму або згенероване ШІ (включно з цим
   документом), звіряти з datasheet або RPi-драйвером перед записом у сенсор.
