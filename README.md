# İstanbul Bizim 🚌 🚇

> **İstanbul'un Tüm İETT Otobüsleri ve Metro Raylı Sistemlerini Gerçek Zamanlı Takip Eden Canlı Harita ve Transit Ağı.**

[![Cloudflare Workers](https://img.shields.io/badge/Cloudflare-Workers-F38020?logo=cloudflare&logoColor=white)](https://workers.cloudflare.com/)
[![Leaflet.js](https://img.shields.io/badge/Leaflet-1.9.4-199900?logo=leaflet&logoColor=white)](https://leafletjs.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## 🌟 Öne Çıkan Özellikler (Key Features)

- **⚡ 6.500+ Canlı İETT Otobüsü (GPS Takibi):**
  - İETT filo servisinden tüm aktif araç koordinatları, anlık hız, operatör ve plaka bilgileriyle çekilir ve Cloudflare KV üzerinde akıllı token-bucket kota korumasıyla (100 req/hr sınırı) önbelleğe alınır.
  - Canlı hız renk kodlaması: **Yeşil** (>15 km/s akıcı), **Sarı** (5-15 km/s yoğun/yavaş), **Gri** (duran/bekleyen araç).
  
- **🎯 0ms Anında Hat Eşleştirme (780+ Hat, 6.400+ Kapı Numarası):**
  - İETT arşiv görev verileriyle derlenen yerleşik veritabanı sayesinde, arama çubuğuna bir hat kodu girildiğinde (`500T`, `15B`, `34G Metrobüs`, `16D`, `E-10`) dış API'ye gitmeden ve kota harcamadan anında haritada filtrelenir.
  
- **🚆 Metro İstanbul Canlı Raylı Sistem Ağı:**
  - 18 raylı sistem hattı (M1A, M1B, M2, M3, M4, M5, M6, M7, M8, M9, T1, T3, T4, T5, F1, F4, TF1, TF2) ve resmi istasyon koordinatları.
  - Sefer tarifelerine göre hat üzerinde saniye saniye hareket eden, sonraki istasyon ve hız simülasyonu yapan canlı trenler.

- **📱 Mobil Uyumlu ve Modern UI/UX:**
  - **Mobil Bottom Sheet (Çekmece):** Apple/Google Maps tarzı sürükleyip bırakılabilir, 3 kademeli (küçültülmüş, orta, tam ekran) arayüz.
  - **Konumumu Bul (GPS Geolocation):** Kullanıcının İstanbul'daki anlık konumunu bularak haritada radar animasyonuyla gösterme.
  - **Yüksek Performanslı Canvas Havuzu:** 5.000+ aracı DOM'u silip baştan oluşturmadan pürüzsüz 60 FPS ile güncelleme (sıfır titreme, düşük bellek tüketimi).
  - **Retina (@2x) & Karanlık/Aydınlık Harita:** CARTO Dark Matter ve Voyager yüksek çözünürlüklü harita katmanları.
  - **Hızlı Filtreleme Rozetleri:** Metrobüs ve popüler hatlara tek tıkla ulaşım.
  - **Klavye Kısayolları:** `/` tuşuyla hızlı arama, `Esc` ile filtre temizleme.

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
