#pragma once

// LovyanGFX-Konfiguration für den ESP32-2432S028.
// Panel-Typ per Build-Flag: PANEL_ILI9341 oder PANEL_ST7789. Getestete Dual-USB-Revision:
// ST7789-Familie (Controller-ID 81 81 B3), keine Farbinvertierung.
// Siehe Blink-Doku: SPI über ca. 32 MHz kann die Panel-Initialisierung verhindern.
// Touch: XPT2046 an eigenem SPI-Bus (VSPI). Mit -DSCREENSHOT ist das Panel lesbar
// (nur Debug-Build, für das Kommando {"t":"shot"}).
// Für abweichende Board-Revisionen per Build-Flag überschreibbar:
//   ROTATION      Bildschirmausrichtung (1 = Querformat; 3 = um 180° gedreht)
//   PANEL_INVERT  1 = Farben invertieren (Hintergrund erscheint sonst weiß)
//   PANEL_SWAP_RB 1 = Rot und Blau tauschen (RGB- statt BGR-Reihenfolge)

#ifndef ROTATION
#define ROTATION 1
#endif
#ifndef PANEL_INVERT
#define PANEL_INVERT 0
#endif
#ifndef PANEL_SWAP_RB
#define PANEL_SWAP_RB 0
#endif

#define LGFX_USE_V1
#include <LovyanGFX.hpp>

class LGFX : public lgfx::LGFX_Device {
#if defined(PANEL_ST7789)
  lgfx::Panel_ST7789 _panel;
#else
  lgfx::Panel_ILI9341 _panel;
#endif
  lgfx::Bus_SPI _bus;
  lgfx::Light_PWM _light;
  lgfx::Touch_XPT2046 _touch;

public:
  LGFX() {
    {
      auto cfg = _bus.config();
      cfg.spi_host = SPI2_HOST;  // HSPI
      cfg.spi_mode = 0;
      cfg.freq_write = 27000000;
      cfg.freq_read = 16000000;
      cfg.spi_3wire = false;
      cfg.use_lock = true;
      cfg.dma_channel = SPI_DMA_CH_AUTO;
      cfg.pin_sclk = 14;
      cfg.pin_mosi = 13;
      cfg.pin_miso = 12;
      cfg.pin_dc = 2;
      _bus.config(cfg);
      _panel.setBus(&_bus);
    }
    {
      auto cfg = _panel.config();
      cfg.pin_cs = 15;
      cfg.pin_rst = -1;  // TFT-Reset ist nicht an einen GPIO geführt
      cfg.pin_busy = -1;
      cfg.panel_width = 240;
      cfg.panel_height = 320;
      cfg.offset_x = 0;
      cfg.offset_y = 0;
      cfg.offset_rotation = 0;
#ifdef SCREENSHOT
      cfg.readable = true;
#else
      cfg.readable = false;
#endif
      cfg.bus_shared = false;  // Touch und SD hängen an eigenen Pins
      cfg.invert = PANEL_INVERT;
      cfg.rgb_order = PANEL_SWAP_RB;
      cfg.dlen_16bit = false;
      _panel.config(cfg);
    }
    {
      auto cfg = _light.config();
      cfg.pin_bl = 21;
      cfg.invert = false;
      cfg.freq = 12000;
      cfg.pwm_channel = 7;
      _light.config(cfg);
      _panel.setLight(&_light);
    }
    {
      auto cfg = _touch.config();
      cfg.spi_host = SPI3_HOST;  // VSPI, eigener Bus
      cfg.freq = 1000000;
      cfg.pin_sclk = 25;
      cfg.pin_mosi = 32;
      cfg.pin_miso = 39;
      cfg.pin_cs = 33;
      cfg.pin_int = 36;
      cfg.bus_shared = false;
      cfg.x_min = 300;
      cfg.x_max = 3900;
      cfg.y_min = 300;
      cfg.y_max = 3900;
      cfg.offset_rotation = 0;
      _touch.config(cfg);
      _panel.setTouch(&_touch);
    }
    setPanel(&_panel);
  }

  // Ohne Reset-Pin behält das Panel Register früherer Firmwares bis zum Stromlos-
  // Machen. Deshalb erst Software-Reset (definierter Zustand), dann initialisieren.
  // Danach DFUNCTR (B6h) mit Gate-Scan GS=1 setzen, wie beim Sichttest der
  // Ausrichtung; Controller ohne dieses Register ignorieren den Befehl.
  bool initPanel() {
    if (!init()) return false;
    startWrite();
    writeCommand(0x01);
    endWrite();
    delay(150);
    if (!init()) return false;
    startWrite();
    writeCommand(0xB6);
    writeData(0x08);
    writeData(0xC2);
    writeData(0x27);
    endWrite();
    return true;
  }
};
