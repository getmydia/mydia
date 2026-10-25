# Translating Mydia

Mydia's web interface is translated on Weblate:
https://hosted.weblate.org/projects/mydia/

You need a free Weblate account, no git and no code. Translations reach Mydia
as pull requests that a maintainer merges, and ship in the next release.

## Translating

1. Open the project, pick the `default` component (the interface) or `errors`
   (form validation messages), and pick your language.
   The Mydia player app has its own `player` component.
2. Keep every `%{name}` placeholder exactly as written. You may move it, never
   rename or translate it. Weblate flags a changed placeholder; CI rejects it.
   In the `player` component placeholders look like `{name}` instead; keep
   those the same way.
3. For plurals, fill every form Weblate shows for your language.
4. Keep the tone plain and direct. Do not translate product names (Mydia, Plex,
   TMDB...).

Partly translated languages are fine: anything untranslated shows in English,
and the language picker shows how complete each language is.

## Adding a language

Start it from the Weblate project page ("Start new translation"). It appears in
Mydia's language picker in the first release after its first translations are
merged.

## Glossary

Use these terms so the interface reads consistently. Discuss changes on Weblate
before changing a term everywhere.

| English | Español | Português (Brasil) |
| --- | --- | --- |
| Library | Biblioteca | Biblioteca |
| Movie | Película | Filme |
| TV show | Serie | Série |
| Season | Temporada | Temporada |
| Episode | Episodio | Episódio |
| Collection | Colección | Coleção |
| Download | Descarga (verb: descargar) | Download (verb: baixar) |
| Download client | Cliente de descargas | Cliente de download |
| Indexer | Indexador | Indexador |
| Quality profile | Perfil de calidad | Perfil de qualidade |
| Custom format | Formato personalizado | Formato personalizado |
| Release | Lanzamiento | Lançamento |
| Grab | Capturar | Capturar |
| Import | Importar | Importar |
| Monitored | Monitorizado | Monitorado |
| Unmonitored | Sin monitorizar | Não monitorado |
| Missing | Faltante | Ausente |
| Wanted | Buscados | Procurados |
| Queue | Cola | Fila |
| Request | Solicitud | Solicitação |
| Subtitle | Subtítulo | Legenda |
| Device | Dispositivo | Dispositivo |
| Plugin | Complemento | Plugin |
| Settings | Ajustes | Configurações |
| Search | Buscar | Buscar |
| Seeders | Semillas | Seeders |
| Peers | Pares | Peers |
| Trash | Papelera | Lixeira |
| Blocklist | Lista de bloqueo | Lista de bloqueio |
| Smart collection | Colección inteligente | Coleção inteligente |
| Shelf | Estante | Estante |
| Section | Sección | Seção |
| Discover | Descubrir | Descobrir |
| Activity | Actividad | Atividade |
| Calendar | Calendario | Calendário |
| Configuration (menu) | Configuración | Configuração |
| Scan (noun / verb) | Escaneo / escanear | Varredura / escanear |
| Re-scan | Reescaneo / volver a escanear | Nova varredura / escanear de novo |
| Match (noun / verb) | Coincidencia / asociar | Correspondência / associar |
| Re-match | Volver a asociar | Associar de novo |
| Dismiss | Descartar | Dispensar |
| Stalled | Estancado | Parado |
| Pin (to sidebar) | Anclar | Fixar |

## Reviewing the seed translations

The Spanish and Brazilian Portuguese translations of the whole web interface
were machine-drafted, and so was the Spanish translation of the player. Native
speakers: please review them on Weblate.
