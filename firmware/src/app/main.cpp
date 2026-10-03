// Claude-Usage-Display: empfängt Usage-Stand, Session-Status und Session-Listen als
// NDJSON über USB-Serial (115200 Baud) und zeigt sie an. Tippen wechselt die Seite.
// Protokoll: siehe README.md, Abschnitt "Protokoll".

#include <Arduino.h>
#include <ArduinoJson.h>

#include "ui.h"

static const char *FW_VERSION = "2.4.0";
static const uint32_t OFFLINE_AFTER_MS = 90000;
static const uint32_t FRAME_MS = 40;            // Bildaufbau (Dot-Animation braucht < 300 ms)
static const uint32_t TAP_GAP_MS = 300;         // Entprellung: so lange vorher keine Berührung
static const uint32_t PAGE_TIMEOUT_MS = 60000;  // ohne Touch zurück auf Seite 0
static const int LDR_PIN = 34;
static const uint16_t LDR_DARK = 40, LDR_BRIGHT = 10;  // höher = dunkler
static const uint8_t LDR_HOLD_S = 10;                  // so lange muss ein Wechsel anstehen
static const uint8_t BRIGHTNESS_DAY = 255, BRIGHTNESS_DARK = 26;  // dunkel: ca. 10 %
static const uint32_t FADE_MS = 1000;

static char line[1024];
static size_t lineLen = 0;
static bool discarding = false;

static ViewModel vm;
static char err[48] = "";
static char dots[32] = "";
static bool haveData = false;
static uint32_t lastRxMs = 0;
static int64_t hostEpoch = 0;  // zuletzt empfangene Host-Uhrzeit ...
static uint32_t hostEpochMs = 0;  // ... und wann sie ankam

static bool locked = false;  // Windows-Sitzung gesperrt (bleibt auch offline erhalten)
static bool dark = false;    // Raum dunkel laut LDR (Start: hell)
static uint16_t ldr = 0;     // letzter LDR-Mittelwert (roh)

static uint8_t page = 0;
static uint32_t lastTouchMs = 0, lastTapMs = 0;

static int64_t nowEpoch() {
  return hostEpoch > 0 ? hostEpoch + (int64_t)((millis() - hostEpochMs) / 1000) : 0;
}

static uint8_t targetBrightness() {
  return locked ? 0 : dark ? BRIGHTNESS_DARK : BRIGHTNESS_DAY;
}

// Zahl lesen; nimmt auch Gleitkomma an. Fehlt sie, gilt def.
static int64_t readNum(JsonVariantConst v, int64_t def) {
  return v.is<double>() ? (int64_t)llround(v.as<double>()) : def;
}

// Nur druckbares ASCII übernehmen, die Schriften kennen nichts anderes.
static void copyAscii(char *dst, const char *src, size_t n) {
  size_t k = 0;
  for (; *src && k + 1 < n; src++) {
    unsigned char c = (unsigned char)*src;
    if (c >= 0x20 && c < 0x7F) dst[k++] = (char)c;
  }
  dst[k] = 0;
}

static void readWindow(JsonVariantConst v, Window &w) {
  w.pct = v["p"] | -1.0f;
  w.reset = v["r"] | (int64_t)0;
  w.forecast = readNum(v["f"], -1);
  w.expect = (int)constrain(readNum(v["e"], -1), (int64_t)-1, (int64_t)100);
}

static void handleState(const JsonDocument &doc) {
  int64_t now = doc["now"] | (int64_t)0;
  if (now > 1600000000LL && now < 4102444800LL) {
    hostEpoch = now;
    hostEpochMs = millis();
  }
  vm.tzMin = constrain((int)(doc["tz"] | 0), -840, 840);
  readWindow(doc["s"], vm.session);
  readWindow(doc["w"], vm.week);
  vm.fetchedAt = doc["at"] | (int64_t)0;
  copyAscii(err, doc["err"] | "", sizeof err);
  locked = doc["lock"].as<bool>();

  // Dots: ein Zeichen je Session (w/a/i, max. 24), '|' trennt lokale und Remote-Sessions.
  const char *d = doc["d"] | "";
  size_t n = 0;
  int sessions = 0;
  for (; *d && n < sizeof dots - 1; d++) {
    if (*d == '|' || (strchr("wai", *d) && ++sessions <= 24)) dots[n++] = *d;
  }
  dots[n] = 0;

  // Session-Zeile: x = {s: a|w|i, n: Titel, m: weitere aktive}; fehlt x, bleibt die Zeile leer.
  JsonVariantConst x = doc["x"];
  const char st = (x["s"] | "")[0];
  vm.sess.st = st && strchr("awi", st) ? st : 0;
  copyAscii(vm.sess.name, x["n"] | "", sizeof vm.sess.name);
  vm.sess.more = (uint8_t)constrain((int)(x["m"] | 0), 0, 99);

  haveData = true;
  lastRxMs = millis();
  Serial.printf("{\"t\":\"ack\",\"s\":%.1f,\"w\":%.1f,\"b\":%u,\"l\":%u}\n", vm.session.pct,
                vm.week.pct, targetBrightness(), ldr);
}


static void handleList(const JsonDocument &doc) {
  int p = doc["p"] | 0;
  if (p < 1 || p > 2) return;
  SessionList &l = vm.list[p - 1];
  l.have = true;
  l.at = readNum(doc["at"], 0);
  copyAscii(l.err, doc["err"] | "", sizeof l.err);
  copyAscii(l.label, doc["l"] | "", sizeof l.label);
  l.n = 0;
  for (JsonVariantConst it : doc["i"].as<JsonArrayConst>()) {
    if (l.n >= LIST_MAX) break;
    ListItem &e = l.item[l.n++];
    copyAscii(e.name, it["n"] | "", sizeof e.name);
    const char st = (it["s"] | "o")[0];
    e.st = st && strchr("wai", st) ? st : 'o';
    e.act = readNum(it["a"], 0);
  }
}

static void handleLine(const char *s) {
  JsonDocument doc;
  if (deserializeJson(doc, s)) return;
  const char *t = doc["t"] | "";
  if (!strcmp(t, "state")) {
    handleState(doc);
  } else if (!strcmp(t, "list")) {
    handleList(doc);
#ifdef SCREENSHOT
  } else if (!strcmp(t, "shot")) {
    uiScreenshot();
  } else if (!strcmp(t, "page")) {
    page = (unsigned)(doc["p"] | 0) % 3;  // auch bei negativem p eine gültige Seite
    lastTapMs = millis();
#endif
  }
}

static void pollSerial() {
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (!discarding && lineLen > 0) {
        line[lineLen] = 0;
        handleLine(line);
      }
      lineLen = 0;
      discarding = false;
    } else if (!discarding) {
      if (lineLen < sizeof line - 1) {
        line[lineLen++] = c;
      } else {
        discarding = true;  // überlange Zeile komplett verwerfen
      }
    }
  }
}

// Tippen = nächste Seite. Als neuer Tipp zählt eine Berührung erst, wenn die letzte
// Abfrage keine sah (Flanke; ein langer Redraw dazwischen zählt nicht als Loslassen)
// und vorher 300 ms lang keine war (Entprellung). Bei aus geschaltetem Display ignorieren.
static void pollTouch() {
  static uint32_t lastPoll = 0;
  static bool wasTouched = false;
  if (millis() - lastPoll < 20) return;
  lastPoll = millis();
  const bool touched = uiTouched();
  const bool edge = touched && !wasTouched;
  wasTouched = touched;
  if (!touched) return;
  const bool fresh = edge && millis() - lastTouchMs > TAP_GAP_MS;
  lastTouchMs = millis();
  if (!fresh || targetBrightness() == 0) return;
  page = (page + 1) % 3;
  lastTapMs = millis();
}

static uint16_t readLdr() {
  uint32_t sum = 0;
  for (int i = 0; i < 32; i++) sum += analogRead(LDR_PIN);
  return sum / 32;
}

// Auto-Helligkeit: LDR 1x/s, "dunkel" ab > 40, "hell" unter 10, jeweils erst wenn der
// Wert 10 s ansteht. Gesperrt: Backlight aus. Übergänge weich (ca. 1 s).
static void updateBrightness() {
  static uint32_t lastSample = 0;
  static uint8_t holdS = 0;
  if (millis() - lastSample >= 1000) {
    lastSample = millis();
    ldr = readLdr();
    // Während der Sperre misst der LDR ohne eigenes Backlight zu dunkel: nicht auswerten.
    const bool flip = !locked && (dark ? ldr < LDR_BRIGHT : ldr > LDR_DARK);
    holdS = flip ? holdS + 1 : 0;
    if (holdS > LDR_HOLD_S) {  // 11 Messungen in Folge = 10 s
      dark = !dark;
      holdS = 0;
    }
  }

  static uint8_t from = BRIGHTNESS_DAY, to = BRIGHTNESS_DAY, cur = BRIGHTNESS_DAY;
  static uint32_t fadeStart = 0;
  const uint8_t target = targetBrightness();
  if (target != to) {
    from = cur;
    to = target;
    fadeStart = millis();
  }
  const uint32_t t = millis() - fadeStart;
  cur = t >= FADE_MS ? to : (uint8_t)(from + ((int)to - from) * (int)t / (int)FADE_MS);
  uiSetBrightness(cur);
}

void setup() {
  Serial.setRxBufferSize(2048);
  Serial.begin(115200);
  analogSetPinAttenuation(LDR_PIN, ADC_0db);
  ldr = readLdr();
  uiBegin(FW_VERSION);
  Serial.printf("{\"t\":\"hello\",\"fw\":\"%s\"}\n", FW_VERSION);
}

void loop() {
  pollSerial();
  pollTouch();
  updateBrightness();

  static uint32_t lastFrame = 0;
  if (millis() - lastFrame < FRAME_MS) return;
  lastFrame = millis();

  if (page != 0 && millis() - lastTapMs > PAGE_TIMEOUT_MS) page = 0;
  vm.page = page;
  vm.now = nowEpoch();
  vm.err = err;
  vm.dots = dots;
  if (!haveData) {
    vm.screen = Screen::Waiting;
  } else if (millis() - lastRxMs > OFFLINE_AFTER_MS) {
    vm.screen = Screen::Offline;
    vm.offlineSecs = (millis() - lastRxMs) / 1000;
  } else {
    vm.screen = Screen::Usage;
  }
  uiRender(vm);
}
