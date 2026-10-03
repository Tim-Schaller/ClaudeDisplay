// Claude-Usage-Display: empfängt Usage-Stand, Session-Status und Session-Listen als
// NDJSON über USB-Serial (115200 Baud) und zeigt sie an. Tippen auf eine Session bittet
// den Host, sie am PC zu öffnen; seitwärts wischen oder woanders tippen wechselt die Seite.
// Protokoll: siehe README.md, Abschnitt "Protokoll".

#include <Arduino.h>
#include <ArduinoJson.h>

#include "ui.h"

static const char *FW_VERSION = "2.6.0";
static const uint32_t OFFLINE_AFTER_MS = 90000;
static const uint32_t FRAME_MS = 40;            // Bildaufbau (Dot-Animation braucht < 300 ms)
static const uint32_t RELEASE_MS = 100;         // so lange ohne Kontakt = losgelassen
static const int SWIPE_PX = 50;                 // waagrechter Weg für einen Wisch
static const uint32_t PAGE_TIMEOUT_MS = 60000;  // ohne Touch zurück auf Seite 0
static const uint32_t FADE_MS = 1000;
static const uint32_t DONE_FLASH_MS = 250;  // Hinweis "Session fertig": so lange invertiert

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

static uint8_t page = 0;
static uint32_t lastTapMs = 0;  // letzte Geste (für PAGE_TIMEOUT_MS)
static uint32_t doneAt = 0;     // wann der Host "Session fertig" meldete
static bool doneFlash = false;

static int64_t nowEpoch() {
  return hostEpoch > 0 ? hostEpoch + (int64_t)((millis() - hostEpochMs) / 1000) : 0;
}

static uint8_t targetBrightness() {
  return locked ? 0 : 255;
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

  // Session-Zeile: x = {s: a|w|i, n: Titel, m: weitere aktive, t: wartet seit, o: öffenbar};
  // fehlt x, bleibt die Zeile leer.
  JsonVariantConst x = doc["x"];
  const char st = (x["s"] | "")[0];
  vm.sess.st = st && strchr("awi", st) ? st : 0;
  copyAscii(vm.sess.name, x["n"] | "", sizeof vm.sess.name);
  vm.sess.more = (uint8_t)constrain((int)(x["m"] | 0), 0, 99);
  vm.sess.since = readNum(x["t"], 0);
  vm.sess.open = (x["o"] | 0) == 1;

  haveData = true;
  lastRxMs = millis();
  Serial.printf("{\"t\":\"ack\",\"s\":%.1f,\"w\":%.1f,\"b\":%u}\n", vm.session.pct, vm.week.pct,
                targetBrightness());
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
    e.open = (it["o"] | 0) == 1;
    e.ctx = (int8_t)constrain((int)(it["c"] | -1), -1, 100);
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
  } else if (!strcmp(t, "done")) {  // eine Session ist fertig: kurz blitzen
    doneAt = millis();
    doneFlash = true;
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

// Bittet den Host, die getippte Session zu öffnen (p = Seite, i = Zeile bzw. -1 für die
// Session-Zeile, n = angezeigter Titel; x/y nur zur Diagnose der Touch-Kalibrierung).
static void sendOpen(int hit, const char *name, int x, int y) {
  JsonDocument d;
  d["t"] = "open";
  d["p"] = page;
  d["i"] = hit;
  d["n"] = name;
  d["x"] = x;
  d["y"] = y;
  serializeJson(d, Serial);
  Serial.print('\n');
}

// Gesten, ausgewertet beim Loslassen: waagrecht wischen = Seite wechseln (nach links die
// nächste, nach rechts die vorige); tippen (kaum Bewegung) auf eine Session = am PC öffnen,
// sonst nächste Seite; anders gewischt = nichts. Losgelassen ist erst nach RELEASE_MS ohne
// Kontakt, gerechnet ab der ersten Abfrage ohne Kontakt (der Touch meldet beim Drücken
// einzelne Aussetzer; ein langer Redraw dazwischen zählt nicht als Loslassen).
// Bei ausgeschaltetem Display ignorieren.
static void pollTouch() {
  static uint32_t lastPoll = 0, upAt = 0;
  static bool down = false, up = false;
  static int x0 = 0, y0 = 0, x1 = 0, y1 = 0;  // Start- und letzte Position
  if (millis() - lastPoll < 20) return;
  lastPoll = millis();
  int x, y;
  if (uiTouch(&x, &y)) {
    if (!down) {
      x0 = x;
      y0 = y;
    }
    x1 = x;
    y1 = y;
    down = true;
    up = false;
    return;
  }
  if (!down) return;
  if (!up) {
    up = true;
    upAt = millis();
  }
  if (millis() - upAt < RELEASE_MS) return;
  down = up = false;
  if (targetBrightness() == 0) return;
  lastTapMs = millis();
  const int dx = x1 - x0, dy = y1 - y0;
  if (abs(dx) >= SWIPE_PX && abs(dx) > 2 * abs(dy)) {
    page = (page + (dx < 0 ? 1 : 2)) % 3;
    return;
  }
  if (abs(dx) >= SWIPE_PX || abs(dy) >= SWIPE_PX) return;
  vm.page = page;  // uiHit prüft gegen die angezeigte Seite
  const int hit = uiHit(vm, x0, y0);
  if (hit == HIT_NONE) {
    page = (page + 1) % 3;
    return;
  }
  sendOpen(hit, hit == HIT_SESSION ? vm.sess.name : vm.list[page - 1].item[hit].name, x0, y0);
  uiFlash(hit);
}

// Backlight voll an, bei gesperrter Windows-Sitzung aus; Übergänge weich (ca. 1 s).
// (Der Lichtsensor ist zu unzuverlässig: in einem Gehäuse misst er schon bei normalem
// Raumlicht "dunkel".)
static void updateBrightness() {
  static uint8_t from = 255, to = 255, cur = 255;
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
  uiBegin(FW_VERSION);
  Serial.printf("{\"t\":\"hello\",\"fw\":\"%s\"}\n", FW_VERSION);
}

void loop() {
  pollSerial();
  pollTouch();
  updateBrightness();
  if (doneFlash && millis() - doneAt >= DONE_FLASH_MS) doneFlash = false;
  uiInvert(doneFlash && targetBrightness() > 0);

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
