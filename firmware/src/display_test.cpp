// Phase 1: Display-Test.
// Richtig konfiguriert heißt: Hintergrund schwarz, jeder Balken hat die Farbe
// seiner Beschriftung, Text ist lesbar (nicht gespiegelt) und "oben links"
// steht oben links.

#include <Arduino.h>
#include "lgfx_cyd.h"

#if defined(PANEL_ST7789)
static const char *ENV_NAME = "ST7789";
#else
static const char *ENV_NAME = "ILI9341";
#endif

struct Bar {
  const char *label;
  uint32_t rgb888;
};

// Reines Rot und Blau sind nötig: Ein Rot/Blau-Tausch fällt bei Grün nicht auf.
static const Bar BARS[] = {
    {"ROT", 0xFF0000},   {"GRUEN", 0x00FF00}, {"BLAU", 0x0000FF},
    {"GELB", 0xFFFF00},  {"WEISS", 0xFFFFFF}, {"SCHWARZ", 0x000000},
};

static LGFX lcd;

void setup() {
  Serial.begin(115200);
  Serial.printf("Display-Test, env=%s\n", ENV_NAME);

  lcd.initPanel();
  lcd.setRotation(ROTATION);  // Querformat 320x240 (4..7 = gespiegelte Varianten)
  lcd.setBrightness(255);
  lcd.fillScreen(TFT_BLACK);

  lcd.setTextColor(TFT_WHITE, TFT_BLACK);
  lcd.setTextSize(2);
  lcd.setTextDatum(top_left);
  lcd.drawString("<- oben links", 4, 4);
  lcd.setTextDatum(top_right);
  lcd.drawString(ENV_NAME, lcd.width() - 4, 4);
  lcd.setTextDatum(middle_center);
  lcd.drawString("TEST " + String(ROTATION) + " ->", lcd.width() / 2, 205);

  const int n = sizeof(BARS) / sizeof(BARS[0]);
  const int top = 30, h = 150, w = lcd.width() / n;
  lcd.setTextSize(1);
  lcd.setTextDatum(top_center);
  for (int i = 0; i < n; i++) {
    const int x = i * w;
    lcd.fillRect(x, top, w, h, BARS[i].rgb888);
    lcd.drawRect(x, top, w, h, TFT_DARKGREY);  // macht den schwarzen Balken sichtbar
    lcd.drawString(BARS[i].label, x + w / 2, top + h + 6);
  }

  lcd.setTextDatum(bottom_left);
  lcd.setTextSize(1);
  lcd.drawString("Hintergrund muss schwarz sein", 4, lcd.height() - 6);
}

void loop() { delay(1000); }
