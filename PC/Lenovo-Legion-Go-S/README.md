# Lenovo Legion Go S (83L3) — Linux Yapılandırması

Lenovo Legion Go S el konsolunda Fedora / Ultramarine Linux üzerinde gamepad, touchpad, Y1/Y2 tuşları ve Steam Input'u çalıştıran betik ve ayar dosyaları.

Kontrolcü USB kimliği: `1a86:e310`

## Klasör yapısı

```text
Lenovo-Legion-Go-S/
└── legion-go-s-yedekler/
    ├── legion-go-s-kontrolcu-cozum.sh      Teşhis, yedek, çözüm ve geri alma betiği
    ├── ayarlar/
    │   ├── lenovo-go-s-touchpad-fix.conf   Betiğin /etc/modprobe.d altına kurduğu dosya
    │   └── hhd-state.yml                   Çözüm uygulandıktan sonraki Handheld Daemon ayarları
    └── referans/
        └── sysfs-donanim-durumu.txt        Kontrolcü MCU'sunun donanım öznitelikleri (referans)
```

## Çözülen sorun

Betikteki ve `lenovo-go-s-touchpad-fix.conf` içindeki nota göre:

- `hid_lenovo_go_s` modülü kontrolcünün tüm HID arayüzlerini yalnızca `hidraw` olarak açıyor. Bu yüzden touchpad (`hid-multitouch`) ve kısayol klavyesi (`hid-generic`) için `/dev/input/event*` düğümleri oluşmuyor.
- `xpad` modülü kara listede (`blacklist xpad`) ve `kernel-modules-extra` paketi kurulu olmadığı için XInput kontrolcü çalışmıyor.

`uygula` komutu şunları yapar:

1. Mevcut ayarların yedeğini alır.
2. Kontrolcü MCU'sunda touchpad'i açar (`touchpad/enabled=true`).
3. `hid_lenovo_go_s` modülünü kara listeye alır ve kaldırır, HID arayüzlerini yeniden bağlar.
4. `gamepad-blacklist.conf` dosyasını kaldırır, gerekirse `kernel-modules-extra` kurar, `xpad` modülünü yükler.
5. `hhd@root.service` servisini yeniden başlatır ve Y1/Y2 tuşlarını Steam Input moduna alır (`paddles_as=steam_input`).

## Kullanım

Betiği, yanındaki `ayarlar/` klasörü bozulmadan çalıştırın:

```bash
cd PC/Lenovo-Legion-Go-S/legion-go-s-yedekler
./legion-go-s-kontrolcu-cozum.sh teshis     # hiçbir şeyi değiştirmez
./legion-go-s-kontrolcu-cozum.sh yedekle
./legion-go-s-kontrolcu-cozum.sh uygula     # onay ister
./legion-go-s-kontrolcu-cozum.sh geri-al    # son yedeği geri yükler
```

Komutsuz çalıştırırsanız menü açılır. Yedekler varsayılan olarak `~/İndirilenler/legion-go-s-yedekler` altına alınır, `YEDEK_DIZINI=/yol` ile değiştirilebilir.

## Notlar

- Kontrolcünün HID numarası (`...E310.0003`) ve USB yolu (`5-1`) betik tarafından otomatik bulunur, sabit değildir.
- Yedekleme `/etc/hhd` içinden yalnızca `state.yml` ve `plugins.yml` dosyalarını alır. `.token` dosyası yedeğe girmez. Eski bir sürümde tüm klasör kopyalandığı için token repoya sızmıştı, bu davranış düzeltildi.
- Yedek klasörü yalnızca kullanıcıya okunur (`700`) olarak oluşturulur.
- Betiği gerçek cihazda bu repodan test etmedim. Söz dizimi `shellcheck` ile, cihaz bulma ve yedekleme mantığı sahte bir sysfs ağacıyla denendi. `uygula` komutunu önce `teshis` çıktısına bakarak çalıştırın.
