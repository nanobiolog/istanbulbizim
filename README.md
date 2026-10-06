# İstanbul Bizim 🚌 🚇

> **İstanbul'un Tüm İETT Otobüsleri ve Metro Raylı Sistemlerini Gerçek Zamanlı Takip Eden Canlı Harita ve Transit Ağı.**

[![Cloudflare Workers](https://img.shields.io/badge/Cloudflare-Workers-F38020?logo=cloudflare&logoColor=white)](https://workers.cloudflare.com/)
[![Leaflet.js](https://img.shields.io/badge/Leaflet-1.9.4-199900?logo=leaflet&logoColor=white)](https://leafletjs.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## 🌟 Öne Çıkan Özellikler (Key Features)

- **⚡ 6.500+ Canlı İETT Otobüsü & 99 İstek/Saat Hızlandırılmış Senkronizasyon:**
  - İETT filo servisinden tüm aktif araç koordinatları akıllı token-bucket kota korumasıyla saatte 99 isteğe (her 36.4 saniyede bir) optimize edilmiş aralıkla çekilir.
  - Canlı hız renk kodlaması: **Yeşil** (>15 km/s akıcı), **Sarı** (5-15 km/s yoğun/yavaş), **Gri** (duran/bekleyen araç).

- **🗺️ Canlı Hat Güzergahı ve Çift Yön Çizimi (Gidiş & Dönüş):**
  - Arama kutusundan veya rozetlerden bir hat seçildiğinde (örn. `15B`, `500T`, `34G Metrobüs`), İETT güzergah ve durak veritabanından hattın resmi güzergahı çekilerek harita üzerinde neon parlama efektli hat çizgileri olarak çizilir:
    - **Dönüş Yönü (Cyan `#06b6d4`):** Başlangıçtan varış noktasına giden güzergah ve sıralı duraklar.
    - **Gidiş Yönü (Mor `#a855f7`):** Karşı yönde hareket eden güzergah ve sıralı duraklar.
  - Başlangıç ve son duraklar özel terminal bayraklarıyla işaretlenir, ara duraklara tıklanarak durak kodları ve sıra numaraları görüntülenebilir.
  - Yön filtreleme butonlarıyla tek tıkla sadece istenen yöne odaklanılabilir.

- **🧭 Hangi Otobüsün Hangi Yöne Gittiğini Canlı Tespit Etme:**
  - Hattaki her bir aracın anlık rotası, sefer kodu ve durak geometrisiyle eşleştirilerek hangi yöne gittiği (`➔ KURAN KURSU`, `➔ ÜSKÜDAR CAMİİ ÖNÜ`) ve en yakın durağı tespit edilir.
  - Araç listesi yön bazında gruplanır (`KURAN KURSU Yönü (X Araç)`, `ÜSKÜDAR Yönü (Y Araç)`).
  - Harita üzerindeki araçlar yön renkleriyle ve aracın gittiği pusula açısına (bearing) göre dönen SVG yön oklarıyla gösterilir.

- **🎛️ 2D Gerçek Zamanlı Kalman Filtresi (Kalman Filter for GPS Smoothing):**
  - Gürültülü, binalar arasında sapan (şehir kanyonları) veya seyrek aralıklarla gelen ham GPS verileri matematiksel **2 Boyutlu Kalman Filtresi** (`KalmanBusTracker`) ile filtrelenir.
  - Durum modeli: $x = [\text{lat}, \text{lon}, v_{\text{lat}}, v_{\text{lon}}]^T$.
  - İki veri paketi arasındaki dinamik zaman farkı ($\Delta t$) ve kentsel otobüs ivme belirsizliği ($Q = 1.2\text{ m/s}^2$, $R = 10\text{ m}$) hesaplanarak GPS sapmaları temizlenir, fizik kurallarına uygun pürüzsüz rota takibi ve anlık yön kestirimi sağlanır.

- **🛣️ Akıllı Haritaya Kilitleme (Road Snapping & Map-Matching):**
  - OSRM ve spatial hash grid indeksleme ile filtrelenen otobüs koordinatları en yakın karayolu/otobüs yolu segmentine kilitlenir.
  - Araçların binaların veya denizlerin üzerinden geçmesi engellenir, sokak dönüş açıları gerçek yol geometrisiyle uyumlu hale getirilir.

- **⏸️ Durakta Bekleme ve Yolcu İndirme/Bindirme Tespiti (Bus Stop Waiting Status):**
  - Otobüsün durağa olan fiziksel mesafesi ($\le 65\text{ m}$) ve anlık hızı ($\le 6\text{ km/s}$) canlı analiz edilerek aracın durakta yolcu beklediği anında tespit edilir.
  - Harita üzerinde durak bekleyen araçlar özel amber puls ve **`⏸️ DURAKTA`** rozetiyle gösterilir.
  - Durak noktalarına tıklandığında durakta bekleyen aracın kapı numarası ve plakası listelenir; araç kartlarında ve popup pencerelerinde canlı durak bekleme durumu vurgulanır.

- **✨ 60 FPS Pürüzsüz Araç Animasyon Motoru (Glide Animation & Smoothstep):**
  - Otobüsler koordinat güncellemelerinde harita üzerinde aniden sıçramaz veya kaybolup tekrar belirmez (`requestAnimationFrame` tabanlı 60 FPS sürekli enterpolasyon).
  - Smoothstep eğrisi ve decaying drift sönümlemesiyle sokaklar boyunca akıcı süzülme sağlanır.

- **🚆 Metro İstanbul Canlı Raylı Sistem Ağı & Kalibre Edilmiş Kinematik Motoru:**
  - 18 raylı sistem hattı (M1A, M1B, M2, M3, M4, M5, M6, M7, M8, M9, T1, T3, T4, T5, F1, F4, TF1, TF2) ve resmi istasyon koordinatları.
  - Hat türüne göre gerçekçi ivme/fren dinamikleri:
    - **Sürücüsüz Metro (M5, M8):** İvmelenme $1.0\text{ - }1.1\text{ m/s}^2$, Frenleme $1.1\text{ - }1.2\text{ m/s}^2$.
    - **Hafif Metro / Tramvay (M1, T1, T4):** İvmelenme $1.0\text{ - }1.2\text{ m/s}^2$, Frenleme $1.1\text{ - }1.3\text{ m/s}^2$.
    - **Füniküler & Teleferik (F1, F4, TF1, TF2):** İvmelenme $0.7\text{ - }0.8\text{ m/s}^2$, Frenleme $0.8\text{ - }0.9\text{ m/s}^2$.
    - **Standart İstanbul Metrosu (M2, M4, M7 vb.):** Ort. İvme $0.89\text{ m/s}^2$, Ort. Fren $1.04\text{ m/s}^2$.
  - Saniye saniye durak ve varış süresi geri sayımı (ETA) ve istasyon bekleme süreleri simülasyonu.

- **📱 Mobil Uyumlu ve Modern UI/UX:**
  - **Mobil Bottom Sheet (Çekmece):** Apple/Google Maps tarzı sürükleyip bırakılabilir, 3 kademeli arayüz.
  - **Konumumu Bul (GPS Geolocation):** Kullanıcının İstanbul'daki anlık konumunu bularak haritada radar animasyonuyla gösterme.
  - **Retina (@2x) & Karanlık/Aydınlık Harita:** CARTO Dark Matter ve Voyager yüksek çözünürlüklü harita katmanları.
  - **2.5 Saniyede Bir Hızlı ETag/304 Yoklama:** İstemci tarafı bant genişliği tüketmeden en düşük gecikmeyle anlık filo güncellemelerini alır.

---

## 🏗️ Mimari & Teknoloji (Architecture)

```
[İETT SOAP API / Açık Veri] 
       │
       ▼ (Akıllı Token Bucket & Kota Koruması)
[Cloudflare Workers + KV (LIVE)]
       │
       ├─► /buses           (Tüm aktif filo GPS verisi)
       ├─► /line?code=500T  (Hatta ait anlık araçlar)
       ├─► /lines/map       (Kapı no -> Hat kodu eşleşmesi)
       ├─► /metro/stations  (Metro istasyon koordinatları)
       └─► /status          (Saatlik kota ve sistem sağlığı)
       │
       ▼ (HTML5 Canvas & Leaflet.js)
[Modern Web Uygulaması (Mobil & Masaüstü)]
```

---

## 🚀 Kurulum ve Dağıtım (Getting Started)

### 1. Depoyu Klonlayın
```bash
git clone https://github.com/nanobiolog/istanbulbizim.git
cd istanbulbizim
```

### 2. Cloudflare Wrangler Yapılandırması
Cloudflare KV namespace oluşturun ve örnek yapılandırma dosyasını kopyalayın:
```bash
# KV Namespace oluştur
npx wrangler kv namespace create LIVE

# Örnek yapılandırma dosyasını kopyalayın
cp wrangler.toml.example wrangler.toml
```

`wrangler.toml` dosyasını açıp oluşturduğunuz KV namespace ID'sini yazın:
```toml
[[kv_namespaces]]
binding = "LIVE"
id = "<KV_NAMESPACE_ID>"
```

### 3. Projeyi Derleyin ve Canlıya Alın
```bash
# bundle.js oluştur
python3 build.py

# Cloudflare Workers'a deploy et
npx wrangler deploy
```

---

## 🔑 İBB API Anahtarı (İsteğe Bağlı)

İBB Açık Veri Portalı API anahtarınız varsa Worker'a gizli değişken (secret) olarak ekleyebilirsiniz:
```bash
npx wrangler secret put IBB_API_KEY
```
*(İstendiğinde API anahtarınızı yapıştırınız. Kod bu anahtarı hem HTTP hem SOAP isteklerine otomatik olarak uygular).*

---

## 🛰️ Yerel Veri Besleyici (feeder.py)

İsteğe bağlı olarak yerel makinenizden veya bir sunucudan filo verilerini düzenli beslemek için:
```bash
# Ortam değişkeni ile worker adresini belirleyin (opsiyonel)
export WORKER_URL="https://your-worker.workers.dev"

# Veri besleyiciyi çalıştırın
python3 feeder.py
```

---

## 📄 Lisans

Bu proje [MIT Lisansı](LICENSE) kapsamında açık kaynak olarak sunulmaktadır.
Veri kaynağı: [İstanbul Büyükşehir Belediyesi (İBB) Açık Veri Portalı](https://data.ibb.gov.tr/) & İETT.
