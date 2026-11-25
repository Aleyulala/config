#!/usr/bin/env bash
# ==============================================================================
# Lenovo Legion Go S (83L3 - 1a86:e310) Fedora / Ultramarine Linux
# Gamepad, Touchpad, Özel Tuşlar (Y1/Y2/Steam/QAM) ve Steam Input
# Teşhis, Yedekleme, Güvenli Çözüm ve Geri Alma Betiği
# ==============================================================================
# Kullanım:
#   ./legion-go-s-kontrolcu-cozum.sh teshis    -> Hiçbir şeyi değiştirmeden teşhis eder
#   ./legion-go-s-kontrolcu-cozum.sh yedekle   -> Mevcut ayarların yedeğini alır
#   ./legion-go-s-kontrolcu-cozum.sh uygula    -> Onay alarak güvenli çözümü uygular
#   ./legion-go-s-kontrolcu-cozum.sh geri-al   -> Son yedeği geri yükler
# ==============================================================================

set -u

BACKUP_BASE_DIR="${HOME}/İndirilenler/legion-go-s-yedekler"
LATEST_BACKUP_LINK="${BACKUP_BASE_DIR}/son-yedek"
HID_GOS_CFG="/sys/bus/hid/devices/0003:1A86:E310.0003"

bilgi()  { printf "\n\033[1;34m[BİLGİ]\033[0m %s\n" "$*"; }
basari() { printf "\033[1;32m[TAMAM]\033[0m %s\n" "$*"; }
uyari()  { printf "\033[1;33m[UYARI]\033[0m %s\n" "$*"; }
hata()   { printf "\033[1;31m[HATA]\033[0m %s\n" "$*"; }

# ------------------------------------------------------------------------------
# 1. SALT OKUNUR TEŞHİS KOMUTLARI (Hiçbir dosyayı/ayarı değiştirmez)
# ------------------------------------------------------------------------------
teshis_et() {
    bilgi "1. Dağıtım, Kernel, Cihaz Modeli (DMI), Masaüstü Oturumu ve Steam Paketi Kontrolü"
    echo "-> Dağıtım sürümü (/etc/fedora-release):"
    cat /etc/fedora-release
    echo "-> Aktif kernel sürümü (uname -r):"
    uname -r
    echo "-> Anakart ve cihaz modeli (DMI):"
    head -n 1 /sys/class/dmi/id/product_name /sys/class/dmi/id/product_version /sys/class/dmi/id/board_name 2>/dev/null
    echo "-> Masaüstü oturumu (XDG değişkenleri):"
    env | grep -E 'XDG_CURRENT_DESKTOP|XDG_SESSION_TYPE|DESKTOP_SESSION'
    echo "-> Kurulu Steam, HHD ve kernel paketleri (RPM):"
    rpm -qa | grep -iE 'steam|xpad|hhd|inputplumber|legion|kernel-modules' | sort
    echo "-> Flatpak Steam kontrolü:"
    flatpak list 2>/dev/null | grep -i steam || echo "Flatpak Steam kurulu değil (Sistem RPM paketi kullanılıyor)."

    bilgi "2. USB, HID ve Giriş Aygıtları ile Bağlı Sürücülerin Kontrolü"
    echo "-> USB üzerindeki kontrolcü (lsusb):"
    lsusb | grep -iE '1a86|e310|e311|legion' || lsusb
    echo "-> 1a86:e310 USB arayüzleri (5-1:1.0 .. 5-1:1.6) ve bağlı sürücüler:"
    for i in /sys/bus/usb/devices/5-1:1.*; do
        if [ -d "$i" ]; then
            drv="$(basename "$(readlink -f "$i/driver" 2>/dev/null)" 2>/dev/null)"
            printf "  %s | if=%s class=%s/%s/%s | driver=%s\n" \
                "$i" \
                "$(cat "$i/bInterfaceNumber" 2>/dev/null)" \
                "$(cat "$i/bInterfaceClass" 2>/dev/null)" \
                "$(cat "$i/bInterfaceSubClass" 2>/dev/null)" \
                "$(cat "$i/bInterfaceProtocol" 2>/dev/null)" \
                "${drv:-YOK}"
        fi
    done

    echo "-> HID veri yolundaki aygıtlar ve sürücüleri (/sys/bus/hid/devices):"
    for d in /sys/bus/hid/devices/*; do
        drv="$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null)"
        name="$(grep '^HID_NAME=' "$d/uevent" 2>/dev/null | cut -d= -f2-)"
        printf "  %s -> driver=%s (%s)\n" "$(basename "$d")" "${drv:-YOK}" "${name:-?}"
    done

    echo "-> /proc/bus/input/devices içindeki aktif giriş düğümleri:"
    grep -E '^[INSH]:' /proc/bus/input/devices

    bilgi "3. Kernel Modülleri, Kara Listeler, Donanım Ayarları, HHD ve Steam Input Kontrolü"
    echo "-> Yüklü ilgili kernel modülleri (lsmod):"
    lsmod | grep -iE 'hid|xpad|lenovo|legion|wmi|uinput|joydev'
    echo "-> xpad ve hid_lenovo_go_s modül bilgisi (modinfo):"
    modinfo hid_lenovo_go_s 2>&1 | head -n 10
    modinfo xpad 2>&1 | head -n 5
    echo "-> /etc/modprobe.d/ içindeki yapılandırmalar:"
    head -n 20 /etc/modprobe.d/* 2>/dev/null
    if [ -d "$HID_GOS_CFG" ]; then
        echo "-> Legion Go S MCU / Touchpad / Gamepad donanım öznitelikleri ($HID_GOS_CFG):"
        head -n 5 "$HID_GOS_CFG"/os_mode* "$HID_GOS_CFG"/gamepad/* "$HID_GOS_CFG"/touchpad/* "$HID_GOS_CFG"/imu/* 2>/dev/null
    fi
    echo "-> Handheld Daemon (hhd@root.service) durumu:"
    systemctl status hhd@root.service --no-pager -n 15 2>&1
    echo "-> Steam Input yapılandırma satırları (~/.local/share/Steam/config/config.vdf):"
    grep -iE 'controller|gamepad|steaminput|SDL' "${HOME}/.local/share/Steam/config/config.vdf" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# 2. YEDEKLEME FONKSİYONU
# ------------------------------------------------------------------------------
yedekle() {
    ts="$(date +%Y%m%d-%H%M%S)"
    hedef="${BACKUP_BASE_DIR}/yedek-${ts}"
    mkdir -p "$hedef/etc-modprobe.d" "$hedef/etc-udev-rules.d" "$hedef/steam-config" "$hedef/sysfs-snapshot"

    bilgi "Mevcut yapılandırmalar yedekleniyor: $hedef"
    cp -a /etc/modprobe.d/* "$hedef/etc-modprobe.d/" 2>/dev/null || true
    cp -a /etc/udev/rules.d/* "$hedef/etc-udev-rules.d/" 2>/dev/null || true
    if [ -f "${HOME}/.local/share/Steam/config/config.vdf" ]; then
        cp -a "${HOME}/.local/share/Steam/config/config.vdf" "$hedef/steam-config/config.vdf"
    fi
    if [ -d /etc/hhd ]; then
        sudo cp -a /etc/hhd "$hedef/etc-hhd" 2>/dev/null || true
    fi
    if [ -d "$HID_GOS_CFG" ]; then
        head -n 20 "$HID_GOS_CFG"/os_mode* "$HID_GOS_CFG"/gamepad/* "$HID_GOS_CFG"/touchpad/* "$HID_GOS_CFG"/imu/* > "$hedef/sysfs-snapshot/hid-gos-sysfs.txt" 2>&1 || true
    fi
    rpm -qa | sort > "$hedef/installed-rpms.txt"
    ln -sfn "$hedef" "$LATEST_BACKUP_LINK"
    basari "Yedekleme tamamlandı: $hedef"
}

# ------------------------------------------------------------------------------
# 3. GÜVENLİ ÇÖZÜM UYGULAMA FONKSİYONU
# ------------------------------------------------------------------------------
uygula() {
    echo "=============================================================================="
    echo "Uygulanacak İşlemler:"
    echo "  1. Mevcut ayarların tam yedeği alınacak."
    echo "  2. Kontrolcü MCU'sunda kapalı kalan touchpad etkinleştirilecek (touchpad/enabled=true)."
    echo "  3. Touchpad ve kısayol klavyesini (0003:1A86:E310.0001 ve .0002) yalnızca hidraw"
    echo "     modunda kilitleyip /dev/input/event* oluşmasını engelleyen hatalı"
    echo "     'hid_lenovo_go_s' modülü kara listeye alınacak ve kaldırılacak;"
    echo "     böylece touchpad 'hid-multitouch', klavye ise 'hid-generic' ile çalışacak."
    echo "  4. Eksik olan 'kernel-modules-extra-$(uname -r)' paketi kurularak 'xpad' modülü"
    echo "     sağlanacak ve '/etc/modprobe.d/gamepad-blacklist.conf' kaldırılacak."
    echo "  5. XInput arayüzü (5-1:1.1) xpad'e bağlanacak ve 'hhd@root.service' yeniden"
    echo "     başlatılarak Y1, Y2, Steam, Quick Access (...) tuşları ile Steam Input"
    echo "     uyumluluğu etkinleştirilecek."
    echo "=============================================================================="
    printf "Devam etmek istiyor musunuz? [e/H]: "
    read -r onay
    case "$onay" in
        [eE]|[eE][vV][eE][tT]|[yY]) ;;
        *) uyari "İşlem kullanıcı tarafından iptal edildi."; exit 0 ;;
    esac

    yedekle

    bilgi "Adım 1/5: Donanım üzerinde Touchpad etkinleştiriliyor..."
    if [ -w "${HID_GOS_CFG}/touchpad/enabled" ] || [ -e "${HID_GOS_CFG}/touchpad/enabled" ]; then
        echo true | sudo tee "${HID_GOS_CFG}/touchpad/enabled" >/dev/null || true
        basari "Touchpad donanım bayrağı 'true' yapıldı."
    fi

    bilgi "Adım 2/5: Touchpad/Klavye evdev düğümlerini engelleyen hid_lenovo_go_s devre dışı bırakılıyor..."
    sudo tee /etc/modprobe.d/lenovo-go-s-touchpad-fix.conf >/dev/null <<'EOF'
# Kernel 7.2.11 hid-lenovo-go-s modülü tüm 1a86:e310 HID arayüzlerini (.0001-.0006)
# yalnızca HID_CONNECT_HIDRAW (0x04) ile açtığı için hid-multitouch (touchpad) ve
# hid-generic (klavye) evdev düğümlerinin oluşmasını engeller.
# Donanım yapılandırması ve özel tuşlar Handheld Daemon (hhd) tarafından yönetilir.
blacklist hid_lenovo_go_s
EOF
    sudo modprobe -r hid_lenovo_go_s 2>/dev/null || true
    sudo modprobe hid_generic 2>/dev/null || true
    sudo modprobe hid_multitouch 2>/dev/null || true

    # USB HID arayüzlerini yeniden bağla (5-1:1.0 ve 5-1:1.2 artık hid-generic ve hid-multitouch'a bağlanır)
    for intf in 5-1:1.0 5-1:1.2 5-1:1.3 5-1:1.4 5-1:1.5 5-1:1.6; do
        if [ -e "/sys/bus/usb/devices/${intf}" ]; then
            echo "$intf" | sudo tee /sys/bus/usb/drivers/usbhid/unbind >/dev/null 2>&1 || true
            echo "$intf" | sudo tee /sys/bus/usb/drivers/usbhid/bind >/dev/null 2>&1 || true
        fi
    done
    basari "HID arayüzleri hid-generic ve hid-multitouch sürücülerine bağlandı."

    bilgi "Adım 3/5: '/etc/modprobe.d/gamepad-blacklist.conf' kaldırılıyor ve kernel-modules-extra kuruluyor..."
    if [ -f /etc/modprobe.d/gamepad-blacklist.conf ]; then
        sudo rm -f /etc/modprobe.d/gamepad-blacklist.conf
        basari "/etc/modprobe.d/gamepad-blacklist.conf kaldırıldı (yedeği alındı)."
    fi

    if ! modinfo xpad >/dev/null 2>&1; then
        bilgi "Aktif kernel ($(uname -r)) için kernel-modules-extra paketi kuruluyor..."
        sudo dnf install -y "kernel-modules-extra-$(uname -r)" || sudo dnf install -y kernel-modules-extra
    fi

    bilgi "Adım 4/5: xpad modülü yükleniyor ve Legion Go S XInput arayüzüne (1a86:e310) bağlanıyor..."
    sudo modprobe xpad
    if [ -w /sys/bus/usb/drivers/xpad/new_id ] || [ -e /sys/bus/usb/drivers/xpad/new_id ]; then
        echo "1a86 e310" | sudo tee /sys/bus/usb/drivers/xpad/new_id >/dev/null 2>&1 || true
    fi
    sudo udevadm control --reload-rules
    sudo udevadm trigger --subsystem-match=usb --subsystem-match=hid --subsystem-match=input
    sleep 2

    bilgi "Adım 5/5: Handheld Daemon (hhd@root.service) yeniden başlatılıyor ve Y1/Y2 Steam Input modu açılıyor..."
    sudo systemctl restart hhd@root.service
    sleep 3
    sudo hhdctl set controllers.legion_gos.xinput.uinput.paddles_as=steam_input 2>/dev/null || true
    sleep 1

    bilgi "Doğrulama: Güncel giriş aygıtları (/proc/bus/input/devices) ve HHD durumu:"
    grep -E '^[INSH]:' /proc/bus/input/devices
    systemctl status hhd@root.service --no-pager -n 12
    basari "İşlem tamamlandı!"
}

# ------------------------------------------------------------------------------
# 4. GERİ ALMA (ROLLBACK) FONKSİYONU
# ------------------------------------------------------------------------------
geri_al() {
    if [ ! -L "$LATEST_BACKUP_LINK" ] || [ ! -d "$LATEST_BACKUP_LINK" ]; then
        hata "Geri yüklenecek yedek bulunamadı: $LATEST_BACKUP_LINK"
        exit 1
    fi
    yedek_dizin="$(readlink -f "$LATEST_BACKUP_LINK")"
    bilgi "Son yedek geri yükleniyor: $yedek_dizin"

    sudo rm -f /etc/modprobe.d/lenovo-go-s-touchpad-fix.conf
    if [ -f "$yedek_dizin/etc-modprobe.d/gamepad-blacklist.conf" ]; then
        sudo cp -a "$yedek_dizin/etc-modprobe.d/gamepad-blacklist.conf" /etc/modprobe.d/gamepad-blacklist.conf
    fi
    if [ -f "$yedek_dizin/steam-config/config.vdf" ]; then
        cp -a "$yedek_dizin/steam-config/config.vdf" "${HOME}/.local/share/Steam/config/config.vdf"
    fi

    sudo modprobe -r xpad 2>/dev/null || true
    sudo modprobe hid_lenovo_go_s 2>/dev/null || true
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    sudo systemctl restart hhd@root.service 2>/dev/null || true
    basari "Geri alma işlemi tamamlandı."
}

# ------------------------------------------------------------------------------
# ANA GİRİŞ NOKTASI
# ------------------------------------------------------------------------------
komut="${1:-menu}"
case "$komut" in
    teshis|--teshis)
        teshis_et
        ;;
    yedekle|--yedekle)
        yedekle
        ;;
    uygula|--uygula)
        uygula
        ;;
    geri-al|--geri-al)
        geri_al
        ;;
    menu|--menu)
        echo "=============================================================================="
        echo " Lenovo Legion Go S (Fedora / Ultramarine) Kontrolcü ve Touchpad Aracı"
        echo "=============================================================================="
        echo "  1) Çözümü Uygula (Gamepad + Touchpad + Y1/Y2 + Steam Input)"
        echo "  2) Teşhis Et (Salt okunur durum kontrolü)"
        echo "  3) Mevcut Ayarları Yedekle"
        echo "  4) Son Yedeği Geri Yükle (Geri Al)"
        echo "  0) Çıkış"
        echo "=============================================================================="
        printf "Seçiminiz [1-4 / 0]: "
        read -r secim
        case "$secim" in
            1) uygula ;;
            2) teshis_et ;;
            3) yedekle ;;
            4) geri_al ;;
            *) echo "Çıkılıyor."; exit 0 ;;
        esac
        ;;
    *)
        echo "Kullanım: $0 {uygula|teshis|yedekle|geri-al}"
        exit 1
        ;;
esac
