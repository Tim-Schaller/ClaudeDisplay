#pragma once

#include <stdint.h>

static const int LIST_MAX = 7;  // Einträge je Session-Liste

// Ein Limit-Fenster (5-Stunden-Session oder 7-Tage-Woche).
struct Window {
  float pct = -1;         // verbraucht in Prozent, < 0 = unbekannt
  int64_t reset = 0;      // Reset-Zeitpunkt als Unix-Sekunden, 0 = unbekannt
  int64_t forecast = -1;  // 100 % erreicht um (Unix-s), 0 = reicht bis Reset, < 0 = unbekannt
  int expect = -1;        // hochgerechneter Stand beim Reset in % (nur bei forecast 0), < 0 = unbekannt
};

// Session-Zeile auf Seite 0: die wartende (Vorrang) bzw. arbeitende Session.
struct SessionLine {
  char st = 0;         // a wartet, w arbeitet, i alle idle, 0 = keine Angabe
  char name[41] = "";  // Titel (ASCII)
  uint8_t more = 0;    // weitere aktive Sessions
  int64_t since = 0;   // wartet seit (Unix-s), 0 = unbekannt
  bool open = false;   // lässt sich per Tippen am PC öffnen
};

struct ListItem {
  char name[41] = "";  // Titel (ASCII)
  char st = 'o';       // w arbeitet, a wartet, i idle, o offline/beendet
  int64_t act = 0;     // letzte Aktivität als Unix-Sekunden, 0 = unbekannt
  bool open = false;   // lässt sich per Tippen am PC öffnen
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
  uint8_t page = 0;  // 0 Usage, 1 Lokal (dieser Rechner), 2 Remote (andere Rechner)
  Window session, week;
  int64_t now = 0;        // aktuelle Unix-Zeit, 0 = noch keine Uhrzeit vom Host
  int tzMin = 0;          // lokaler UTC-Offset in Minuten (inkl. Sommerzeit)
  int64_t fetchedAt = 0;  // Zeitpunkt des letzten erfolgreichen Abrufs durch den Host
  const char *err = "";   // Fehlermeldung des Hosts, leer = alles gut
  const char *dots = "";  // ein Zeichen je laufender Session (w/a/i), '|' trennt lokal/Remote
  uint32_t offlineSecs = 0;
  SessionLine sess;     // Session-Zeile auf Seite 0
  SessionList list[2];  // Seite 1 (Lokal), Seite 2 (Remote)
};

void uiBegin(const char *fwVersion);
void uiRender(const ViewModel &vm);
void uiSetBrightness(uint8_t level);
bool uiTouch(int *x, int *y);  // berührt? dann mit Bildschirmkoordinaten

// Was liegt unter (x, y) auf der zuletzt gezeichneten Seite: eine Listenzeile (0..LIST_MAX-1),
// die Session-Zeile (HIT_SESSION) oder nichts zum Öffnen (HIT_NONE).
static const int HIT_NONE = -2, HIT_SESSION = -1;
int uiHit(const ViewModel &vm, int x, int y);
void uiFlash(int hit);  // getroffene Zeile kurz hervorheben
#ifdef SCREENSHOT
void uiScreenshot();
#endif
