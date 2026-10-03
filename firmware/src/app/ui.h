#pragma once

#include <stdint.h>

static const int HIST_N = 96;   // Tagesverlauf: 96 Buckets à 15 min (lokale Zeit)
static const int LIST_MAX = 7;  // Einträge je Session-Liste

// Ein Limit-Fenster (5-Stunden-Session oder 7-Tage-Woche).
struct Window {
  float pct = -1;         // verbraucht in Prozent, < 0 = unbekannt
  int64_t reset = 0;      // Reset-Zeitpunkt als Unix-Sekunden, 0 = unbekannt
  int64_t forecast = -1;  // 100 % erreicht um (Unix-s), 0 = reicht bis Reset, < 0 = unbekannt
  int expect = -1;        // hochgerechneter Stand beim Reset in % (nur bei forecast 0), < 0 = unbekannt
};

// Tagesverlauf eines Fensters.
struct Series {
  int64_t day = 0;        // Unix-Sekunden des lokalen Tagesbeginns, 0 = noch nichts empfangen
  int8_t v[HIST_N] = {};  // 0..100, -1 = keine Daten
  uint32_t rev = 0;       // wird bei jedem Empfang erhöht
};

struct ListItem {
  char name[41] = "";  // Titel (ASCII)
  char st = 'o';       // w arbeitet, a wartet, i idle, o offline/beendet
  int64_t act = 0;     // letzte Aktivität als Unix-Sekunden, 0 = unbekannt
};

struct SessionList {
  bool have = false;  // schon eine Liste empfangen
  char label[15] = "";  // Seitentitel vom Host (max. 14 Zeichen), leer = Standardtitel
  int64_t at = 0;     // Abrufzeit beim Host
  char err[48] = "";  // Fehler beim Abruf, leer = alles gut
  uint8_t n = 0;
  ListItem item[LIST_MAX];
};

enum class Screen { Waiting, Usage, Offline };  // Usage = Daten aktuell (alle Seiten)

struct ViewModel {
  Screen screen = Screen::Waiting;
  uint8_t page = 0;  // 0 Usage, 1 Remote (andere Rechner), 2 Lokal (dieser Rechner)
  Window session, week;
  int64_t now = 0;        // aktuelle Unix-Zeit, 0 = noch keine Uhrzeit vom Host
  int tzMin = 0;          // lokaler UTC-Offset in Minuten (inkl. Sommerzeit)
  int64_t fetchedAt = 0;  // Zeitpunkt des letzten erfolgreichen Abrufs durch den Host
  const char *err = "";   // Fehlermeldung des Hosts, leer = alles gut
  const char *dots = "";  // ein Zeichen je laufender Session (w/a/i), '|' trennt lokal/Remote
  uint32_t offlineSecs = 0;
  Series hist[2];       // 0 Session, 1 Woche
  SessionList list[2];  // Seite 1 (Remote), Seite 2 (Lokal)
};

void uiBegin(const char *fwVersion);
void uiRender(const ViewModel &vm);
void uiSetBrightness(uint8_t level);
bool uiTouched();
#ifdef SCREENSHOT
void uiScreenshot();
#endif
