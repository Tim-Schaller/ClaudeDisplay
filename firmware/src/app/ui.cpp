// Darstellung: Kopfzeile (Seitentitel, Seiten-Indikator, Uhrzeit) auf allen Seiten.
// Seite 0: zwei Ring-Gauges (Session 5h, Woche 7d) mit Countdown und Prognose,
// Session-Zeile, Fußzeile mit Session-Dots und Datenstand bzw. Fehler.
// Seiten 1/2: Session-Listen (Lokal, Remote) mit Status-Dot, Titel und Alter.
// Getippte Session-Zeile bzw. Listenzeile wird kurz hervorgehoben (uiFlash).
// Jeder Bereich wird nur neu gezeichnet, wenn sich sein Inhalt ändert; animierte
// Dots einzeln, wenn ihre Phase wechselt.

#include "ui.h"

#include <Arduino.h>
#include <math.h>
#include <string.h>

#include "lgfx_cyd.h"

static LGFX lcd;
static LGFX_Sprite gauge(&lcd);  // 160x188, wird für beide Gauges benutzt
static LGFX_Sprite bar(&lcd);    // 320x26: Kopf-, Fußzeile und Listenzeilen
static LGFX_Sprite dot(&lcd);    // 11x11: ein einzelner Dot (Animation)

static const uint32_t C_BG = 0x000000;
static const uint32_t C_TRACK = 0x262B33;
static const uint32_t C_TEXT = 0xF2F4F7;
static const uint32_t C_DIM = 0x8B95A1;
static const uint32_t C_GREEN = 0x22C55E;
static const uint32_t C_YELLOW = 0xFACC15;
static const uint32_t C_RED = 0xEF4444;
static const uint32_t C_AMBER = 0xF59E0B;
static const uint32_t C_OK = 0x339B59;      // "OK until reset" (0x4ADE80 * 0.7)
static const uint32_t C_PULSE = 0x14532D;   // arbeitende Session, gedimmte Puls-Phase
static const uint32_t C_IDLE = 0x64748B;
static const uint32_t C_OFFLINE = 0x475569;

static const int W = 320, H = 240;
static const int BAR_H = 26, FOOTER_Y = 214, GAUGE_Y = BAR_H;
static const int GW = 160, GH = 158;
static const float GCX = 80, GCY = 66, R_MID = 54, HALF_W = 7;
static const float A_START = -135, A_END = 135;  // Grad, 0 = oben, im Uhrzeigersinn
static const int SESS_Y = 186;                                     // Session-Zeile auf Seite 0
static const int ROW_Y = 28, ROW_H = 26;                          // Listenzeilen
static const int FOOT_DOTS = 24;
static const int64_t WAIT_ALERT_S = 600;  // so lange wartet eine Session, bis die Zeit rot wird
static const uint32_t FLASH_MS = 400;     // getippte Zeile so lange hervorheben
static const uint32_t C_FLASH = 0x334155; // Hintergrund der getippten Zeile

// Standardtitel; für Seite 1/2 kann der Host einen eigenen Titel mitschicken (list.l).
static const char *const PAGE_TITLE[3] = {"Claude Usage", "Local", "Remote"};

static const char *pageTitle(const ViewModel &vm) {
  if (vm.page > 0 && vm.list[vm.page - 1].label[0]) return vm.list[vm.page - 1].label;
  return PAGE_TITLE[vm.page];
}

static const char *gFw = "";
static uint8_t gBrightness = 0;

// Gezeichnete animierte Dots: Fußzeile (Seite 0) und Listenzeilen (Seiten 1/2).
static bool gPulseOn = true, gBlinkOn = true;
static int16_t footX[FOOT_DOTS];
static char footSt[FOOT_DOTS];
static uint8_t footN = 0;
static char rowSt[LIST_MAX];  // 0 = Zeile ohne Dot

// Getippte Zeile (uiFlash) und was gerade hervorgehoben gezeichnet ist.
static int gTapHit = HIT_NONE, gHl = HIT_NONE;
static uint32_t gTapAt = 0;

// --- Hilfsfunktionen -------------------------------------------------------

static uint32_t blend(uint32_t a, uint32_t b, float t) {
  if (t <= 0) return a;
  if (t >= 1) return b;
  int ar = a >> 16 & 255, ag = a >> 8 & 255, ab = a & 255;
  int br = b >> 16 & 255, bg = b >> 8 & 255, bb = b & 255;
  return (uint32_t)(ar + (br - ar) * t) << 16 | (uint32_t)(ag + (bg - ag) * t) << 8 |
         (uint32_t)(ab + (bb - ab) * t);
}

// Grün bis 50 %, dann über Gelb (80 %) nach Rot (ab 95 %).
static uint32_t levelColor(float pct) {
  if (pct <= 50) return C_GREEN;
  if (pct <= 80) return blend(C_GREEN, C_YELLOW, (pct - 50) / 30);
  if (pct <= 95) return blend(C_YELLOW, C_RED, (pct - 80) / 15);
  return C_RED;
}

// Sekunden seit lokaler Mitternacht.
static int localSecs(int64_t t, int tzMin) {
  t += (int64_t)tzMin * 60;
  return (int)(((t % 86400) + 86400) % 86400);
}

static void fmtHM(char *out, size_t n, int64_t t, int tzMin) {
  int s = localSecs(t, tzMin);
  snprintf(out, n, "%02d:%02d", s / 3600, s / 60 % 60);
}

static void fmtCountdown(char *out, size_t n, const Window &w, int64_t now) {
  if (w.reset <= 0 || now <= 0) {
    snprintf(out, n, "Reset --");
    return;
  }
  int64_t s = w.reset - now;
  if (s <= 0) {
    snprintf(out, n, "Reset now");
    return;
  }
  // Erst aufrunden, dann die Einheit wählen (sonst "60m" bzw. "24h 00m").
  int mins = (int)((s + 59) / 60);
  if (mins < 60) {
    snprintf(out, n, "Reset %dm", mins);
  } else if (mins < 24 * 60) {
    snprintf(out, n, "Reset %dh %02dm", mins / 60, mins % 60);
  } else {
    int hours = (int)((s + 3599) / 3600);
    snprintf(out, n, "Reset %dd %dh", hours / 24, hours % 24);
  }
}

// Prognose: "Limit ~HH:MM" (mehr als 20 h voraus mit Wochentag), "~64% @ Reset"
// (hochgerechneter Stand beim Reset) oder leer (zu wenig Daten). Liefert die Textfarbe.
static uint32_t fmtForecast(char *out, size_t n, const Window &w, int64_t now, int tzMin) {
  out[0] = 0;
  if (w.forecast < 0) return C_DIM;
  if (w.forecast == 0) {
    if (w.expect >= 0) {
      snprintf(out, n, "~%d%% @ Reset", w.expect);
      return levelColor(w.expect);
    }
    snprintf(out, n, "OK until reset");
    return C_OK;
  }
  char hm[8];
  fmtHM(hm, sizeof hm, w.forecast, tzMin);
  if (now > 0 && w.forecast - now > 20 * 3600) {
    static const char *const DAY[7] = {"Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"};
    int64_t days = (w.forecast + (int64_t)tzMin * 60) / 86400;  // 1.1.1970 = Donnerstag
    snprintf(out, n, "Limit ~%s %s", DAY[(days + 3) % 7], hm);
  } else {
    snprintf(out, n, "Limit ~%s", hm);
  }
  return C_AMBER;
}

// Alter für die Listen: "jetzt", "5 min", "3 h", "2 T"; leer, wenn unbekannt.
static void fmtAge(char *out, size_t n, int64_t t, int64_t now) {
  int64_t s = now - t;
  if (t <= 0 || now <= 0) {
    out[0] = 0;
  } else if (s < 60) {
    snprintf(out, n, "now");
  } else if (s < 3600) {
    snprintf(out, n, "%dm", (int)(s / 60));
  } else if (s < 86400) {
    snprintf(out, n, "%dh", (int)(s / 3600));
  } else {
    snprintf(out, n, "%dd", (int)(s / 86400 > 999 ? 999 : s / 86400));
  }
}

// Wartezeit für die Session-Zeile: "<1m", "12m", "3h", "2d"; leer = unbekannt.
static void fmtWait(char *out, size_t n, int64_t since, int64_t now) {
  if (since > 0 && now > 0 && now - since < 60) {
    snprintf(out, n, "<1m");
  } else {
    fmtAge(out, n, since, now);
  }
}

// Kürzt buf auf maxW Pixel in der aktuellen Schrift von g, auf Wunsch mit "...".
// buf braucht dann Platz für 3 weitere Zeichen.
static void fitText(LovyanGFX &g, char *buf, int maxW, bool ellipsis) {
  if (g.textWidth(buf) <= maxW) return;
  if (ellipsis) maxW -= g.textWidth("...");
  for (size_t n = strlen(buf); n > 0 && (g.textWidth(buf) > maxW || buf[n - 1] == ' ');) {
    buf[--n] = 0;
  }
  if (ellipsis) strcat(buf, "...");
}


// --- Dots ------------------------------------------------------------------

// w: grün, pulsiert; a: gelb, blinkt; i: grau; o: nur Ring.
static void paintDot(LovyanGFX &g, int x, int y, int r, char st) {
  switch (st) {
    case 'w':
      g.fillSmoothCircle(x, y, r, gPulseOn ? C_GREEN : C_PULSE);
      break;
    case 'a':
      if (gBlinkOn) g.fillSmoothCircle(x, y, r, C_AMBER);
      break;
    case 'i':
      g.fillSmoothCircle(x, y, r, C_IDLE);
      break;
    default:
      g.drawCircle(x, y, r, C_OFFLINE);
      break;
  }
}

// Einen Dot samt Hintergrund (11x11) direkt neu zeichnen, ohne den Rest anzufassen.
static void pushDot(int x, int y, int r, char st) {
  dot.fillSprite(C_BG);
  paintDot(dot, 5, 5, r, st);
  dot.pushSprite(x - 5, y - 5);
}

static char sessSt = 0;  // Status des Dots in der Session-Zeile (0 = nicht angezeigt)

// Nur die Dots neu zeichnen, deren Phase gewechselt hat (nicht in einer hervorgehobenen
// Zeile: pushDot malt schwarzen Hintergrund).
static void animateDots(bool pulse, bool blink) {
  if (gHl != HIT_SESSION && ((sessSt == 'w' && pulse) || (sessSt == 'a' && blink))) {
    pushDot(14, SESS_Y + BAR_H / 2, 5, sessSt);
  }
  for (int i = 0; i < footN; i++) {
    if ((footSt[i] == 'w' && pulse) || (footSt[i] == 'a' && blink)) {
      pushDot(footX[i], FOOTER_Y + BAR_H / 2, 4, footSt[i]);
    }
  }
  for (int i = 0; i < LIST_MAX; i++) {
    if (gHl != i && ((rowSt[i] == 'w' && pulse) || (rowSt[i] == 'a' && blink))) {
      pushDot(14, ROW_Y + ROW_H / 2 + i * ROW_H, 5, rowSt[i]);
    }
  }
}

// --- Gauge -----------------------------------------------------------------

struct Cap {
  float x, y;
};

static Cap capAt(float deg) {
  float r = deg * DEG_TO_RAD;
  return {R_MID * sinf(r), -R_MID * cosf(r)};
}

// Deckung (0..1) eines Pixels durch einen Bogen mit runden Enden.
static float arcCoverage(float r, float ang, float dx, float dy, float a0, float a1, Cap c0,
                         Cap c1) {
  float d;
  if (ang >= a0 && ang <= a1) {
    d = fabsf(r - R_MID);
  } else {
    d = fminf(hypotf(dx - c0.x, dy - c0.y), hypotf(dx - c1.x, dy - c1.y));
  }
  float cov = HALF_W + 0.5f - d;
  return cov < 0 ? 0 : (cov > 1 ? 1 : cov);
}

static void drawRing(float pct, uint32_t color) {
  const float aV = A_START + (A_END - A_START) * pct / 100.0f;
  const Cap t0 = capAt(A_START), t1 = capAt(A_END), v0 = t0, v1 = capAt(aV);
  const float rIn = R_MID - HALF_W - 1, rOut = R_MID + HALF_W + 1;
  const int x0 = (int)(GCX - rOut), x1 = (int)(GCX + rOut) + 1;
  const int y0 = max(0, (int)(GCY - rOut)), y1 = min(GH - 1, (int)(GCY + rOut) + 1);
  for (int y = y0; y <= y1; y++) {
    for (int x = x0; x <= x1; x++) {
      float dx = x + 0.5f - GCX, dy = y + 0.5f - GCY;
      float r = sqrtf(dx * dx + dy * dy);
      if (r < rIn || r > rOut) continue;
      float ang = atan2f(dx, -dy) * RAD_TO_DEG;
      float covT = arcCoverage(r, ang, dx, dy, A_START, A_END, t0, t1);
      float covV = pct > 0 ? arcCoverage(r, ang, dx, dy, A_START, aV, v0, v1) : 0;
      if (covT <= 0 && covV <= 0) continue;
      gauge.drawPixel(x, y, blend(blend(C_BG, C_TRACK, covT), color, covV));
    }
  }
}

static void renderGauge(int x, const char *title, const Window &w, const char *reset,
                        const char *forecast, uint32_t fcColor) {
  const bool known = w.pct >= 0;
  const float p = known ? fminf(fmaxf(w.pct, 0), 100) : 0;
  gauge.fillSprite(C_BG);
  drawRing(p, levelColor(known ? w.pct : 0));

  char num[8];
  if (known) {
    snprintf(num, sizeof num, "%d", (int)lroundf(w.pct));
  } else {
    strcpy(num, "--");
  }
  // Zahl in 24 pt; passt sie mit "%" nicht in 92 px (z. B. 100 %), dann 18 pt.
  const lgfx::IFont *numFont = &fonts::FreeSansBold24pt7b;
  int wNum = gauge.textWidth(num, numFont);
  const int wPct = known ? gauge.textWidth("%", &fonts::FreeSansBold12pt7b) + 3 : 0;
  if (wNum + wPct > 92) {
    numFont = &fonts::FreeSansBold18pt7b;
    wNum = gauge.textWidth(num, numFont);
  }
  const int nx = (int)GCX - (wNum + wPct) / 2;
  gauge.setTextDatum(baseline_left);
  gauge.setTextColor(known ? C_TEXT : C_DIM);
  gauge.setFont(numFont);
  gauge.drawString(num, nx, (int)GCY + 10);
  if (known) {
    gauge.setFont(&fonts::FreeSansBold12pt7b);
    gauge.drawString("%", nx + wNum + 3, (int)GCY + 10);
  }

  gauge.setTextDatum(middle_center);
  gauge.setFont(&fonts::FreeSans9pt7b);
  gauge.setTextColor(C_DIM);
  gauge.drawString(title, (int)GCX, (int)GCY + 28);
  gauge.setFont(&fonts::FreeSansBold9pt7b);
  gauge.setTextColor(C_TEXT);
  gauge.drawString(reset, (int)GCX, 128);
  if (forecast[0]) {
    gauge.setFont(&fonts::FreeSans9pt7b);
    gauge.setTextColor(fcColor);
    gauge.drawString(forecast, (int)GCX, 146);
  }
  gauge.pushSprite(x, GAUGE_Y);
}

// Session-Zeile unter den Gauges: wartende Session (Vorrang) bzw. arbeitende, mit
// animiertem Dot; rechts die Wartezeit (ab WAIT_ALERT_S rot) und weitere aktive Sessions
// als "+n". Ohne Angabe leer. hl: hervorgehoben (gerade getippt).
static void renderSessionLine(const SessionLine &s, const char *wait, bool alert, bool hl) {
  bar.fillSprite(hl ? C_FLASH : C_BG);
  sessSt = s.st;
  bar.setFont(&fonts::FreeSans9pt7b);
  bar.setTextDatum(middle_left);
  if (s.st == 'i') {
    paintDot(bar, 14, BAR_H / 2, 5, 'i');
    bar.setTextColor(C_DIM);
    bar.drawString("all sessions idle", 28, BAR_H / 2);
  } else if (s.st == 'a' || s.st == 'w') {
    paintDot(bar, 14, BAR_H / 2, 5, s.st);
    const char *prefix = s.st == 'a' ? "waiting: " : "working: ";
    bar.setTextColor(s.st == 'a' ? C_AMBER : C_GREEN);
    bar.drawString(prefix, 28, BAR_H / 2);
    const int x = 28 + bar.textWidth(prefix);
    int right = W - 8;
    bar.setTextDatum(middle_right);
    if (s.more > 0) {
      char more[8];
      snprintf(more, sizeof more, "+%u", s.more);
      bar.setTextColor(C_DIM);
      bar.drawString(more, right, BAR_H / 2);
      right -= bar.textWidth(more) + 8;
    }
    if (wait[0]) {
      bar.setTextColor(alert ? C_RED : C_AMBER);
      bar.drawString(wait, right, BAR_H / 2);
      right -= bar.textWidth(wait) + 8;
    }
    bar.setTextDatum(middle_left);
    char name[sizeof s.name + 3];
    strlcpy(name, s.name, sizeof s.name);
    fitText(bar, name, right - x, true);
    bar.setTextColor(C_TEXT);
    bar.drawString(name, x, BAR_H / 2);
  }
  bar.pushSprite(0, SESS_Y);
}

// --- Kopf-, Fußzeile und Listenzeilen --------------------------------------

static void renderHeader(const char *title, uint8_t page, const char *clock, bool online) {
  bar.fillSprite(C_BG);
  bar.setTextDatum(middle_left);
  bar.setFont(&fonts::FreeSansBold9pt7b);
  bar.setTextColor(C_TEXT);
  char buf[sizeof SessionList::label];  // Host-Label max. 14 Zeichen
  strlcpy(buf, title, sizeof buf);
  fitText(bar, buf, 134, false);  // endet vor dem Seiten-Indikator (ab x = 145)
  bar.drawString(buf, 8, BAR_H / 2);
  for (int i = 0; i < 3; i++) {  // Seiten-Indikator
    bar.fillSmoothCircle(148 + 12 * i, BAR_H / 2, 3, i == page ? C_TEXT : C_DIM);
  }
  bar.setTextDatum(middle_right);
  bar.setFont(&fonts::FreeSansBold12pt7b);
  bar.drawString(clock, W - 8, BAR_H / 2);
  int cw = bar.textWidth(clock);
  bar.fillSmoothCircle(W - 8 - cw - 12, BAR_H / 2, 4, online ? C_GREEN : C_DIM);
  bar.pushSprite(0, 0);
}

// Text links (gekürzt), optional rechts klein der Datenstand.
static void renderFooter(const char *text, uint32_t color, const char *right) {
  bar.fillSprite(C_BG);
  int maxW = W - 16;
  if (right[0]) {
    bar.setTextDatum(middle_right);
    bar.setFont(&fonts::Font0);
    bar.setTextColor(C_DIM);
    bar.drawString(right, W - 8, BAR_H / 2);
    maxW -= bar.textWidth(right) + 10;
  }
  bar.setTextDatum(middle_left);
  bar.setFont(&fonts::FreeSans9pt7b);
  bar.setTextColor(color);
  char buf[64];
  strlcpy(buf, text, sizeof buf);
  fitText(bar, buf, maxW, false);
  bar.drawString(buf, 8, BAR_H / 2);
  bar.pushSprite(0, FOOTER_Y);
  footN = 0;
}

// Dots-Leiste (ein Dot je Session, '|' = Lücke mit Trennlinie) und rechts der Datenstand.
static void renderDotsFooter(const char *dots, const char *right) {
  bar.fillSprite(C_BG);
  bar.setTextDatum(middle_right);
  bar.setFont(&fonts::Font0);
  bar.setTextColor(C_DIM);
  bar.drawString(right, W - 8, BAR_H / 2);
  const int limit = W - 8 - bar.textWidth(right) - 8;  // Dots müssen links davon enden
  footN = 0;
  int x = 10;  // Mittelpunkt des nächsten Dots
  for (const char *p = dots; *p && footN < FOOT_DOTS; p++) {
    if (*p == '|') {
      if (footN > 0 && p[1] && x + 9 + 4 <= limit) {
        bar.drawFastVLine(x - 1, BAR_H / 2 - 6, 13, C_TRACK);  // mittig in der Lücke
      }
      x += 9;
      continue;
    }
    if (x + 4 > limit) break;
    paintDot(bar, x, BAR_H / 2, 4, *p);
    footX[footN] = x;
    footSt[footN++] = *p;
    x += 11;
  }
  bar.pushSprite(0, FOOTER_Y);
}

// Listenzeile i; it == nullptr = leere Zeile. right = Alter bzw. "wartet", davor der
// Kontext-Füllstand (ab 75 % orange, ab 90 % rot). hl: getippt.
static void renderRow(int i, const ListItem *it, const char *right, bool hl) {
  bar.fillSprite(hl ? C_FLASH : C_BG);
  rowSt[i] = it ? it->st : 0;
  if (it) {
    paintDot(bar, 14, ROW_H / 2, 5, it->st);
    bar.setFont(&fonts::FreeSans9pt7b);
    bar.setTextDatum(middle_right);
    bar.setTextColor(it->st == 'a' ? C_AMBER : C_DIM);
    bar.drawString(right, W - 8, ROW_H / 2);
    int titleEnd = W - 8 - bar.textWidth(right) - 10;
    if (it->ctx >= 0) {
      char ctx[8];
      snprintf(ctx, sizeof ctx, "%d%%", it->ctx);
      bar.setTextColor(it->ctx >= 90 ? C_RED : it->ctx >= 75 ? C_AMBER : C_DIM);
      bar.drawString(ctx, titleEnd, ROW_H / 2);
      titleEnd -= bar.textWidth(ctx) + 10;
    }
    char title[sizeof it->name + 3];
    strlcpy(title, it->name[0] ? it->name : "Untitled", sizeof title);
    fitText(bar, title, titleEnd - 28, true);
    bar.setTextDatum(middle_left);
    bar.setTextColor(C_TEXT);
    bar.drawString(title, 28, ROW_H / 2);
  }
  bar.pushSprite(0, ROW_Y + i * ROW_H);
}

// "2 arbeiten, 1 wartet, 3 idle" (Nullwerte weggelassen; offline zeigen die Ringe).
static void fmtSummary(char *out, size_t n, const SessionList &l) {
  static const char ST[3] = {'w', 'a', 'i'};
  static const char *const ONE[3] = {"working", "waiting", "idle"};
  static const char *const MANY[3] = {"working", "waiting", "idle"};
  out[0] = 0;
  for (int k = 0; k < 3; k++) {
    int c = 0;
    for (int i = 0; i < l.n; i++) c += l.item[i].st == ST[k];
    if (!c) continue;
    size_t len = strlen(out);
    snprintf(out + len, n - len, "%s%d %s", len ? ", " : "", c, c == 1 ? ONE[k] : MANY[k]);
  }
  if (!out[0] && l.n) snprintf(out, n, "none active");
}

// --- Offline/Warten --------------------------------------------------------

static void clearContent() { lcd.fillRect(0, BAR_H, W, FOOTER_Y - BAR_H, C_BG); }

static void renderNotice(const char *title, const char *line1, const char *line2,
                         uint32_t accent) {
  clearContent();
  lcd.fillSmoothCircle(W / 2, 82, 26, accent);
  lcd.setTextDatum(middle_center);
  lcd.setFont(&fonts::FreeSansBold18pt7b);
  lcd.setTextColor(C_BG);
  lcd.drawString("!", W / 2, 84);
  lcd.setTextColor(C_TEXT);
  lcd.drawString(title, W / 2, 136);
  lcd.setFont(&fonts::FreeSans9pt7b);
  lcd.setTextColor(C_DIM);
  lcd.drawString(line1, W / 2, 170);
  lcd.drawString(line2, W / 2, 192);
}

// --- Öffentliche Funktionen ------------------------------------------------

void uiBegin(const char *fwVersion) {
  gFw = fwVersion;
  lcd.initPanel();
  lcd.setRotation(ROTATION);
  lcd.fillScreen(C_BG);
  uiSetBrightness(255);
  gauge.setColorDepth(16);
  gauge.createSprite(GW, GH);
  bar.setColorDepth(16);
  bar.createSprite(W, BAR_H);
  dot.setColorDepth(16);
  dot.createSprite(11, 11);
}

void uiSetBrightness(uint8_t level) {
  if (level == gBrightness) return;
  gBrightness = level;
  lcd.setBrightness(level);
}

bool uiTouch(int *x, int *y) {
  uint16_t tx, ty;
  if (lcd.getTouch(&tx, &ty) <= 0) return false;
  *x = tx;
  *y = ty;
  return true;
}

// Öffnen lässt sich nur, was gerade zu sehen ist und laut Host einen Link hat (nicht z. B.
// Terminal-Sessions): auf Seite 0 die Session-Zeile mit wartender bzw. arbeitender
// Session, auf Seite 1/2 eine belegte Listenzeile. Alles andere wechselt die Seite.
int uiHit(const ViewModel &vm, int x, int y) {
  if (vm.screen != Screen::Usage || x < 0 || x >= W) return HIT_NONE;
  if (vm.page == 0) {
    const bool shown = (vm.sess.st == 'a' || vm.sess.st == 'w') && vm.sess.open;
    return shown && y >= SESS_Y && y < SESS_Y + BAR_H ? HIT_SESSION : HIT_NONE;
  }
  const SessionList &l = vm.list[vm.page - 1];
  if (y < ROW_Y) return HIT_NONE;
  const int i = (y - ROW_Y) / ROW_H;
  return i < l.n && i < LIST_MAX && l.item[i].open ? i : HIT_NONE;
}

void uiInvert(bool on) {
  static bool inverted = false;
  if (on == inverted) return;
  inverted = on;
  lcd.invertDisplay(on);  // relativ zu PANEL_INVERT (LovyanGFX)
}

void uiFlash(int hit) {
  gTapHit = hit;
  gTapAt = millis();
}

void uiRender(const ViewModel &vm) {
  static Screen lastScreen = (Screen)-1;
  static uint8_t lastPage = 255;
  static char lastHeader[40], lastFooter[160], lastG[2][128], lastNotice[64], lastSess[80];
  static char lastRow[LIST_MAX][80], lastMode;

  // Animationsphase der Dots: w 600 ms an/gedimmt, a 300 ms an/aus.
  const uint32_t ms = millis();
  const bool pulse = ms / 600 % 2 == 0, blink = ms / 300 % 2 == 0;
  const bool pulseChanged = pulse != gPulseOn, blinkChanged = blink != gBlinkOn;
  gPulseOn = pulse;
  gBlinkOn = blink;
  gHl = ms - gTapAt < FLASH_MS ? gTapHit : HIT_NONE;

  const bool full = vm.screen != lastScreen || vm.page != lastPage;
  if (full) {
    lastScreen = vm.screen;
    lastPage = vm.page;
    lcd.fillScreen(C_BG);
    lastHeader[0] = lastFooter[0] = lastG[0][0] = lastG[1][0] = lastNotice[0] = lastSess[0] = 0;
    for (auto &r : lastRow) r[0] = 0;
    lastMode = 0;
    footN = 0;
    sessSt = 0;
    memset(rowSt, 0, sizeof rowSt);
  }

  // Kopfzeile: Uhrzeit (sobald der Host sie geliefert hat) und Online-Punkt.
  char clock[8] = "--:--";
  if (vm.now > 0) fmtHM(clock, sizeof clock, vm.now, vm.tzMin);
  const char *title = pageTitle(vm);
  char header[sizeof lastHeader];
  snprintf(header, sizeof header, "%s%c%s", clock, vm.screen == Screen::Usage ? '+' : '-', title);
  if (strcmp(header, lastHeader) != 0) {
    strcpy(lastHeader, header);
    renderHeader(title, vm.page, clock, vm.screen == Screen::Usage);
  }

  // Fußzeile: Text links (Farbe), rechts klein der Datenstand, auf Seite 0 statt Text Dots.
  char footText[64] = "", stand[16] = "";
  uint32_t footColor = C_DIM;
  const char *footDots = nullptr;

  if (vm.screen == Screen::Usage && vm.page == 0) {
    const Window *win[2] = {&vm.session, &vm.week};
    static const char *const TITLE[2] = {"Session", "Week"};
    for (int k = 0; k < 2; k++) {
      char reset[32], fc[32], sig[128];
      fmtCountdown(reset, sizeof reset, *win[k], vm.now);
      const uint32_t fcColor = fmtForecast(fc, sizeof fc, *win[k], vm.now, vm.tzMin);
      snprintf(sig, sizeof sig, "%.1f|%s|%s", win[k]->pct, reset, fc);
      if (strcmp(sig, lastG[k]) != 0) {
        strcpy(lastG[k], sig);
        renderGauge(k * GW, TITLE[k], *win[k], reset, fc, fcColor);
      }
    }
    char wait[12] = "", sess[sizeof lastSess];
    if (vm.sess.st == 'a') fmtWait(wait, sizeof wait, vm.sess.since, vm.now);
    const bool alert = wait[0] && vm.now - vm.sess.since >= WAIT_ALERT_S;
    snprintf(sess, sizeof sess, "%c|%u|%s|%d%d|%s", vm.sess.st ? vm.sess.st : '-', vm.sess.more,
             wait, alert, gHl == HIT_SESSION, vm.sess.name);
    if (strcmp(sess, lastSess) != 0) {
      strcpy(lastSess, sess);
      renderSessionLine(vm.sess, wait, alert, gHl == HIT_SESSION);
    }
    if (vm.err[0]) {
      snprintf(footText, sizeof footText, "%s", vm.err);
      footColor = C_AMBER;
    } else {
      strcpy(stand, "@ --:--");
      if (vm.fetchedAt > 0) fmtHM(stand + 2, sizeof stand - 2, vm.fetchedAt, vm.tzMin);
      footDots = vm.dots;
    }
  } else if (vm.screen == Screen::Usage) {
    const SessionList &l = vm.list[vm.page - 1];
    const char mode = !l.have ? 'N' : l.n ? 'L' : 'E';  // nichts empfangen / Liste / leer
    if (mode != lastMode) {
      lastMode = mode;
      clearContent();
      for (auto &r : lastRow) r[0] = 0;
      memset(rowSt, 0, sizeof rowSt);
      if (mode != 'L') {
        lcd.setTextDatum(middle_center);
        lcd.setFont(&fonts::FreeSans9pt7b);
        lcd.setTextColor(C_DIM);
        lcd.drawString(mode == 'N' ? "Waiting for data" : "No sessions", W / 2, 120);
      }
    }
    for (int i = 0; mode == 'L' && i < LIST_MAX; i++) {
      const ListItem *it = i < l.n ? &l.item[i] : nullptr;
      char right[12] = "", sig[80] = "";
      if (it) {
        if (it->st == 'a') {
          strcpy(right, "waiting");
        } else {
          fmtAge(right, sizeof right, it->act, vm.now);
        }
        snprintf(sig, sizeof sig, "%c|%s|%d|%d|%s", it->st, right, it->ctx, gHl == i, it->name);
      }
      if (strcmp(sig, lastRow[i]) != 0) {
        strcpy(lastRow[i], sig);
        renderRow(i, it, right, it && gHl == i);
      }
    }
    if (l.err[0]) {
      strlcpy(footText, l.err, sizeof footText);
      footColor = C_AMBER;
    } else {
      fmtSummary(footText, sizeof footText, l);
    }
    if (l.have) {
      strcpy(stand, "@ --:--");
      if (l.at > 0) fmtHM(stand + 2, sizeof stand - 2, l.at, vm.tzMin);
    }
  } else if (vm.screen == Screen::Waiting) {
    if (lastNotice[0] != 'W') {
      strcpy(lastNotice, "W");
      renderNotice("Waiting for data", "USB connected.", "Start the collector on the PC", C_DIM);
    }
    snprintf(footText, sizeof footText, "Firmware %s", gFw);
  } else {
    char notice[64], line1[48];
    uint32_t mins = vm.offlineSecs / 60;
    if (mins < 2) {
      snprintf(line1, sizeof line1, "No data for %lu s", (unsigned long)vm.offlineSecs / 30 * 30);
    } else if (mins < 120) {
      snprintf(line1, sizeof line1, "No data for %lu min", (unsigned long)mins);
    } else {
      snprintf(line1, sizeof line1, "No data for %lu h", (unsigned long)(mins / 60));
    }
    snprintf(notice, sizeof notice, "O|%s", line1);
    if (strcmp(notice, lastNotice) != 0) {
      strcpy(lastNotice, notice);
      renderNotice("Offline", line1, "Is the collector running?", C_AMBER);
    }
    char s[8] = "--", w[8] = "--";
    if (vm.session.pct >= 0) snprintf(s, sizeof s, "%d%%", (int)lroundf(vm.session.pct));
    if (vm.week.pct >= 0) snprintf(w, sizeof w, "%d%%", (int)lroundf(vm.week.pct));
    snprintf(footText, sizeof footText, "Last: Session %s | Week %s", s, w);
  }

  char footer[160];
  snprintf(footer, sizeof footer, "%c%s|%06lx|%s|%s", footDots ? 'D' : 'T',
           footDots ? footDots : "", (unsigned long)footColor, footText, stand);
  if (strcmp(footer, lastFooter) != 0) {
    strcpy(lastFooter, footer);
    if (footDots) {
      renderDotsFooter(footDots, stand);
    } else {
      renderFooter(footText, footColor, stand);
    }
  }

  if (pulseChanged || blinkChanged) animateDots(pulseChanged, blinkChanged);
}

#ifdef SCREENSHOT
// Debug: Bildschirm zeilenweise als Hex ausgeben ("S <y> <320 x RGB565>", dann "S end").
void uiScreenshot() {
  static uint16_t px[W];
  static char hex[W * 4 + 1];
  // Animierte Dots in der An-Phase zeichnen, sonst fehlen blinkende Dots im Bild.
  gPulseOn = gBlinkOn = true;
  animateDots(true, true);
  for (int y = 0; y < H; y++) {
    lcd.readRect(0, y, W, 1, px);
    for (int x = 0; x < W; x++) snprintf(hex + x * 4, 5, "%04X", px[x]);
    Serial.printf("S %d ", y);
    Serial.write(hex, W * 4);
    Serial.write('\n');
  }
  Serial.println("S end");
}
#endif
