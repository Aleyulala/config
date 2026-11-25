#!/usr/bin/env bash
# ==============================================================================
# Waydroid TV (Fedora / KDE Plasma) Otomatik APK Yükleyici Kurulum Betiği
# Dosya: /home/lenova/İndirilenler/apk-kaydet.sh
#
# Bu betik:
# 1. Fedora'da herhangi bir .apk dosyasına tıklandığında (Dolphin, Tarayıcı vb.)
#    otomatik olarak Waydroid TV içine kurulmasını sağlar.
# 2. Waydroid TV (Android 16) içindeki WayDroidService.installApp PendingIntent
#    hatasını (IllegalArgumentException) aşmak için kurulumu doğrudan konteyner
#    içindeki `pm install -r -g` üzerinden yapacak şekilde yapılandırır.
# 3. Waydroid kapalıysa (STOPPED) otomatik olarak oturumu başlatır, kurulum
#    başladığında ve bittiğinde masaüstü bildirimi (notify-send) gösterir.
# 4. Android TV uygulamalarının (LEANBACK_LAUNCHER) Fedora uygulama menüsüne
#    kısayol olarak düşmesini sağlar.
#
# Kullanım:
#   Kurulumu/ayarları uygulamak için:
#     ./apk-kaydet.sh
#   Doğrudan bir APK yüklemek için:
#     ./apk-kaydet.sh /yol/uygulama.apk
# ==============================================================================

set -euo pipefail

PASS="ali"
USER_NAME="lenova"
USER_HOME="/home/${USER_NAME}"

if [ "$(id -u)" -ne 0 ]; then
    echo "$PASS" | sudo -S -v 2>/dev/null || true
fi

run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Eğer argüman olarak bir .apk dosyası verildiyse doğrudan yükle
if [ "${1:-}" != "" ] && [ -f "${1:-}" ]; then
    exec /usr/local/bin/waydroid-apk-yukle "$1"
fi

echo "=== [1/6] Sudoers Yetkilendirmesi (Şifresiz APK Kurulumu İçin) ==="
run_root tee /etc/sudoers.d/waydroid-apk-install >/dev/null <<EOF
${USER_NAME} ALL=(root) NOPASSWD: /usr/bin/lxc-attach, /usr/bin/waydroid, /usr/bin/systemctl start waydroid-container.service
EOF
run_root chmod 0440 /etc/sudoers.d/waydroid-apk-install

echo "=== [2/6] Waydroid Otomatik APK Yükleyici Betiği (/usr/local/bin/waydroid-apk-yukle) ==="
run_root tee /usr/local/bin/waydroid-apk-yukle >/dev/null <<'EOF'
#!/usr/bin/env bash
set -u

if [ "$#" -lt 1 ]; then
    echo "Kullanım: waydroid-apk-yukle <dosya.apk> [dosya2.apk ...]" >&2
    exit 1
fi

notify_user() {
    local title="$1"
    local body="$2"
    local icon="${3:-waydroid}"
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -a "Waydroid APK Yükleyici" -i "$icon" "$title" "$body" 2>/dev/null || true
    fi
}

ensure_waydroid_running() {
    # Konteyner servisi çalışmıyorsa başlat
    if ! systemctl is-active --quiet waydroid-container.service; then
        sudo -n systemctl start waydroid-container.service 2>/dev/null || true
    fi

    # Konteyner RUNNING değilse oturumu arka planda başlat
    local lxc_state
    lxc_state="$(sudo -n lxc-info -P /var/lib/waydroid/lxc -n waydroid -sH 2>/dev/null || echo "STOPPED")"
    if [ "$lxc_state" = "FROZEN" ]; then
        waydroid container unfreeze 2>/dev/null || true
        lxc_state="RUNNING"
    fi

    if [ "$lxc_state" != "RUNNING" ]; then
        notify_user "Waydroid Başlatılıyor" "APK kurulumu için Waydroid TV oturumu açılıyor, lütfen bekleyin..."
        systemd-run --user --collect waydroid session start >/dev/null 2>&1 || nohup waydroid session start >/tmp/waydroid-session-autostart.log 2>&1 &
    fi

    # Android tamamen açılana kadar (sys.boot_completed=1) bekle (maks 45 sn)
    for _ in $(seq 1 45); do
        local boot_done
        boot_done="$(sudo -n lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- /system/bin/getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')"
        if [ "$boot_done" = "1" ]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

TMP_DIR="${HOME}/.local/share/waydroid/data/waydroid_tmp"
mkdir -p "$TMP_DIR"

if ! ensure_waydroid_running; then
    notify_user "Waydroid Hatası" "Waydroid TV konteyneri başlatılamadı." "dialog-error"
    exit 1
fi

for APK_PATH in "$@"; do
    # file:// şemasını temizle
    APK_PATH="${APK_PATH#file://}"
    if [ ! -f "$APK_PATH" ]; then
        notify_user "APK Bulunamadı" "Dosya bulunamadı: $APK_PATH" "dialog-error"
        continue
    fi

    APK_NAME="$(basename "$APK_PATH")"
    TMP_FILE="install_$$_${RANDOM}.apk"
    HOST_TMP="${TMP_DIR}/${TMP_FILE}"
    CONTAINER_TMP="/data/waydroid_tmp/${TMP_FILE}"

    notify_user "APK Yükleniyor..." "${APK_NAME} Waydroid TV'ye kuruluyor..."

    cp -f "$APK_PATH" "$HOST_TMP"
    chmod 0644 "$HOST_TMP"

    INSTALL_OUT="$(sudo -n lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- /system/bin/pm install -r -g "$CONTAINER_TMP" 2>&1)"
    INSTALL_RC=$?
    rm -f "$HOST_TMP"

    if [ $INSTALL_RC -eq 0 ] && echo "$INSTALL_OUT" | grep -qi "Success"; then
        # Android TV'de adaptive-icon banner'ların oval/kesik görünmesini önleyen dikdörtgen maskeyi etkinleştir
        if ! sudo -n lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- /system/bin/cmd overlay list android 2>/dev/null | grep -q "\[x\] com.android.shell:TvRectIconMask"; then
            sudo -n lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- /system/bin/cmd overlay fabricate --target android --name TvRectIconMask android:string/config_icon_mask 0x03 "M0,0H100V100H0Z" 2>/dev/null || true
            sudo -n lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- /system/bin/cmd overlay enable com.android.shell:TvRectIconMask 2>/dev/null || true
        fi

        # Yeni kurulan uygulamanın masaüstü kısayolunu (~/.local/share/applications) ve ikonunu güncelle
        APK_ENV_PATH="$APK_PATH" python3 - <<'SYNC_EOF' 2>/dev/null || true
import os, sys, zipfile
from pathlib import Path
sys.path.insert(0, "/usr/lib/waydroid")
from tools.interfaces import IPlatform
from gi.repository import GLib
class Args:
    config = "/var/lib/waydroid/waydroid.cfg"
    BINDER_DRIVER = "binder"; VNDBINDER_DRIVER = "vndbinder"; HWBINDER_DRIVER = "hwbinder"
    SERVICE_MANAGER_PROTOCOL = "aidl6"; BINDER_PROTOCOL = "aidl3"
svc = IPlatform.get_service(Args())
if svc:
    apps_dir = Path.home() / ".local/share/applications"
    icons_dir = Path.home() / ".local/share/waydroid/data/icons"
    apps_dir.mkdir(0o700, exist_ok=True)
    icons_dir.mkdir(0o777, exist_ok=True)
    apk_path = os.environ.get("APK_ENV_PATH", "")
    system_apps = {
        "com.android.calculator2", "com.android.camera2", "com.android.contacts",
        "com.android.deskclock", "com.android.documentsui", "com.android.email",
        "com.android.gallery3d", "com.android.inputmethod.latin", "com.android.settings",
        "com.android.tv.settings", "com.google.android.gms", "org.lineageos.aperture",
        "org.lineageos.eleven", "org.lineageos.etar", "org.lineageos.jelly", "org.lineageos.recorder"
    }
    for app in svc.getAppsInfo():
        cats = [c.strip() for c in app.get("categories", [])]
        if not any(c in ("android.intent.category.LAUNCHER", "android.intent.category.LEANBACK_LAUNCHER") for c in cats):
            continue
        pkg = app["packageName"]
        icon_file = icons_dir / f"{pkg}.png"
        if not icon_file.exists() and apk_path and os.path.isfile(apk_path):
            try:
                with zipfile.ZipFile(apk_path, "r") as zf:
                    candidates = [
                        n for n in zf.namelist()
                        if n.endswith(".png") and not n.endswith(".9.png")
                        and ("ic_launcher" in n or "icon" in n.lower())
                        and "banner" not in n.lower()
                    ]
                    if candidates:
                        best = max(candidates, key=lambda n: zf.getinfo(n).file_size)
                        icon_file.write_bytes(zf.read(best))
            except Exception:
                pass
        df_path = apps_dir / f"waydroid.{pkg}.desktop"
        kf = GLib.KeyFile()
        kf.set_string("Desktop Entry", "Type", "Application")
        kf.set_string("Desktop Entry", "Name", app["name"])
        kf.set_string("Desktop Entry", "Exec", f"waydroid app launch {pkg}")
        kf.set_string("Desktop Entry", "Icon", str(icon_file))
        kf.set_string_list("Desktop Entry", "Categories", ["X-WayDroid-App"])
        kf.set_string_list("Desktop Entry", "X-Purism-FormFactor", ["Workstation", "Mobile"])
        if pkg in system_apps:
            kf.set_boolean("Desktop Entry", "NoDisplay", True)
        kf.save_to_file(str(df_path))
SYNC_EOF
        notify_user "APK Kurulumu Tamamlandı" "${APK_NAME} başarıyla Waydroid TV'ye yüklendi!"
        echo "[OK] ${APK_NAME} yüklendi."
    else
        notify_user "APK Kurulum Hatası" "${APK_NAME} yüklenemedi: ${INSTALL_OUT}" "dialog-error"
        echo "[HATA] ${APK_NAME}: ${INSTALL_OUT}" >&2
        exit 1
    fi
done
EOF
run_root chmod 0755 /usr/local/bin/waydroid-apk-yukle

echo "=== [3/6] Waydroid app_manager.py ve user_manager.py (Android 16 TV) Yaması ==="
run_root python3 - <<'PYEOF'
from pathlib import Path

# 1. app_manager.py: WayDroidService.installApp Android 16'da PendingIntent hatası verdiği için
#    pm install -r -g yedeklemesi ve benzersiz geçici dosya adı ekle.
app_mgr = Path("/usr/lib/waydroid/tools/actions/app_manager.py")
text = app_mgr.read_text()
old_block = """        shutil.copyfile(args.PACKAGE, tmp_dir + "/base.apk")
        platformService = IPlatform.get_service(args)
        if platformService:
            platformService.installApp("/data/waydroid_tmp/base.apk")
        else:
            logging.error("Failed to access IPlatform service")
        os.remove(tmp_dir + "/base.apk")"""

new_block = """        apk_tmp_name = f"install_{os.getpid()}.apk"
        host_apk_tmp = f"{tmp_dir}/{apk_tmp_name}"
        container_apk_tmp = f"/data/waydroid_tmp/{apk_tmp_name}"
        shutil.copyfile(args.PACKAGE, host_apk_tmp)
        os.chmod(host_apk_tmp, 0o644)
        try:
            import subprocess
            res = subprocess.run(
                ["sudo", "-n", "lxc-attach", "-P", "/var/lib/waydroid/lxc", "-n", "waydroid",
                 "--", "/system/bin/pm", "install", "-r", "-g", container_apk_tmp],
                capture_output=True, text=True
            )
            if res.returncode != 0 or "Success" not in res.stdout:
                platformService = IPlatform.get_service(args)
                if platformService:
                    platformService.installApp(container_apk_tmp)
                else:
                    logging.error("Failed to install APK: %s", res.stderr or res.stdout)
        finally:
            if os.path.exists(host_apk_tmp):
                os.remove(host_apk_tmp)"""

if old_block in text:
    app_mgr.write_text(text.replace(old_block, new_block))
    print("app_manager.py güncellendi.")
elif "install_{os.getpid()}.apk" in text:
    print("app_manager.py zaten güncel.")

# 2. user_manager.py: Android TV (LEANBACK_LAUNCHER) uygulamaları için masaüstü kısayolu desteği ekle.
usr_mgr = Path("/usr/lib/waydroid/tools/services/user_manager.py")
utext = usr_mgr.read_text()
old_cat = 'if cat.strip() == "android.intent.category.LAUNCHER":'
new_cat = 'if cat.strip() in ("android.intent.category.LAUNCHER", "android.intent.category.LEANBACK_LAUNCHER"):'
if old_cat in utext:
    usr_mgr.write_text(utext.replace(old_cat, new_cat))
    print("user_manager.py (LEANBACK_LAUNCHER) güncellendi.")
elif "LEANBACK_LAUNCHER" in utext:
    print("user_manager.py zaten güncel.")

# 3. container_manager.py: Askıda kalan (stale) oturum varsa "Already tracking a session"
#    hatası vermek yerine otomatik temizle ve yeni oturumu başlat.
cnt_mgr = Path("/usr/lib/waydroid/tools/actions/container_manager.py")
ctext = cnt_mgr.read_text()
old_sess = """    if "session" in args:
        raise RuntimeError("Already tracking a session")"""
new_sess = """    if "session" in args:
        old_pid = str(args.session.get("pid", ""))
        if not old_pid or not os.path.exists(f"/proc/{old_pid}"):
            logging.warning("Previous session PID %s is gone; cleaning up stale session", old_pid)
            stop(args, quit_session=False)
        else:
            raise RuntimeError("Already tracking a session")"""
if old_sess in ctext:
    cnt_mgr.write_text(ctext.replace(old_sess, new_sess))
    print("container_manager.py (stale session auto-clean) güncellendi.")
elif "cleaning up stale session" in ctext:
    print("container_manager.py zaten güncel.")
PYEOF

echo "=== [4/6] Yarım Kalan Eski PackageInstaller Dosyalarını Temizleme, TV Banner Düzeltmesi ve İzinler ==="
run_root rm -rf "${USER_HOME}/.local/share/waydroid/data/app"/vmdl*.tmp
if [ "$(run_root lxc-info -P /var/lib/waydroid/lxc -n waydroid -sH 2>/dev/null || true)" = "RUNNING" ]; then
    # Android TV'de adaptive-icon kullanan uygulama banner'larının (örn. CloudStream)
    # yuvarlak maske yüzünden oval/kesik görünmesini engellemek için dikdörtgen RRO maskesi uygula
    run_root lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- /system/bin/cmd overlay fabricate --target android --name TvRectIconMask android:string/config_icon_mask 0x03 "M0,0H100V100H0Z" 2>/dev/null || true
    run_root lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- /system/bin/cmd overlay enable com.android.shell:TvRectIconMask 2>/dev/null || true
    run_root lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- /system/bin/am force-stop org.lineageos.tv.launcher 2>/dev/null || true
    run_root lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- /system/bin/input keyevent KEYCODE_HOME 2>/dev/null || true

    for pkg in com.android.documentsui cm.aptoide.pt com.yandex.browser.tv com.lagradost.cloudstream3 com.lagradost.cloudstream3.debug com.nuvio.tv org.smarttube.stable com.android.htmlviewer com.android.shell; do
        run_root lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- /system/bin/appops set "$pkg" REQUEST_INSTALL_PACKAGES allow 2>/dev/null || true
    done
    run_root lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- /system/bin/settings put global install_non_market_apps 1 2>/dev/null || true
fi

echo "=== [5/6] Masaüstü (.desktop) ve MIME Dosya İlişkilendirmesi ==="
DESKTOP_CONTENT="[Desktop Entry]
Type=Application
Name=Waydroid TV'ye Yükle (APK)
GenericName=Waydroid APK Yükleyici
Comment=Android APK paketlerini Waydroid TV içine kurar
Exec=/usr/local/bin/waydroid-apk-yukle %F
Icon=waydroid
Terminal=false
NoDisplay=false
Categories=System;Utility;
MimeType=application/vnd.android.package-archive;application/apk;
StartupNotify=true
"

echo "$DESKTOP_CONTENT" | run_root tee /usr/share/applications/waydroid.app.install.desktop >/dev/null
mkdir -p "${USER_HOME}/.local/share/applications"
echo "$DESKTOP_CONTENT" > "${USER_HOME}/.local/share/applications/waydroid.app.install.desktop"
chmod 0644 "${USER_HOME}/.local/share/applications/waydroid.app.install.desktop"

xdg-mime default waydroid.app.install.desktop application/vnd.android.package-archive || true
update-desktop-database "${USER_HOME}/.local/share/applications" 2>/dev/null || true
run_root update-desktop-database /usr/share/applications 2>/dev/null || true
if command -v kbuildsycoca6 >/dev/null 2>&1; then
    kbuildsycoca6 >/dev/null 2>&1 || true
fi

echo "=== [6/6] Doğrulama ==="
echo "Varsayılan APK uygulaması: $(xdg-mime query default application/vnd.android.package-archive)"
echo "Kurulum tamamlandı! Artık Fedora'da herhangi bir .apk dosyasına tıkladığınızda otomatik olarak Waydroid TV'ye yüklenecektir."
