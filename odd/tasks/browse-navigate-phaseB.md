# browse_navigate fase B — clics + formularios con sesión

Feature: navegación web en `nim/` como tool nueva `browse_navigate` (fase A `fetch_url` no se toca). Enlaces numerados + formularios básicos, sesión persistida en `.waku/`, bloqueo SSRF solo en la tool nueva, tras `WAKU_EXPERIMENTAL`.

## Specs

S1: Tool nueva `browse_navigate` (fase A `fetch_url` queda igual). User verbatim: "Nueva browse_navigate".
S2: Alcance enlaces + formularios. User verbatim: "Enlaces + formularios".
S3: Sesión persistida en `.waku/`. User verbatim: "Sesión en .waku".
S4: Bloqueo SSRF solo en la tool nueva. User verbatim: "Solo en tool nueva (value: new-only)". `fetch_url` no cambia su política actual.

## Tasks

- T1 (S4): SSRF guard para `browse_navigate` (loopback, red privada, metadata, redirects) + tests RED/GREEN — commit: pending
- T2 (S1,S2): `browse_navigate` paso de lectura (GET + extrae enlaces numerados + texto capado reutilizando `stripTags`/topes) + tests — commit: pending
- T3 (S3): sesión en `.waku/` (crear/cargar, cookies mínimas, retención) + tests — commit: pending
- T4 (S2,S3): formularios básicos (POST con sesión) + tests — commit: pending
- T5 (S1): registro tras `WAKU_EXPERIMENTAL` en `registry.nim` + salida de `plannedTools` si aplica — commit: pending
- T6 (S1-S4): docs que cambien (`docs/roadmap.md`, `docs/benchmarks.md`) + eval determinista (regla 4 AGENTS.md) — commit: pending

## Log

L1: User request verbatim: "vamos con la fase B"
L2: User plan verbatim fase B: "¿Qué debe poder hacer la fase B de browse_web? — Enlaces + formularios"
L3: User plan verbatim estado: "¿Cómo manejamos el estado de navegación entre pasos? — Sesión en .waku"
L4: User asked verbatim: "a que te refieres con el hueco SSRF?" + "explicalo con un ejemplo concreto"
L5: User decision verbatim SSRF: "Solo en tool nueva (value: new-only)"
L6: User plan verbatim forma: "¿Dónde vive la navegación: extendemos fetch_url o creamos tool nueva? — Nueva browse_navigate"
L7: Explorer `gentle-ai-explore mwnnnrma-1-4v45`: mapa fase A (`search.nim:27,50,202,205,210,247,260`, `registry.nim:87-91`, `experimental.nim:41-50`, `config.nim:196`, tests `test_search.nim:73`, `test_registry.nim:87-89`, docs `roadmap.md:43`, `benchmarks.md:222-224`); riesgos binario único y opciones link-follow vs headless vs delegar a `pi`.
L8: Verify `gentle-ai-verify mwnp0w2n-3-nh6` (41 tests GREEN, S4 FAIL): F1 IPv6 alternates, F2 DNS aliases, F3 cross-host cookie leak + misattribution, F4 prune unwired, F5 redirect coverage, F6 docs retention, F7 perms/Domain.
L9: User verbatim: "corrígelos ahora". Fixes: IPv6 normalizado (solo 2000::/3 pasa, mapeadas se juzgan como IPv4), DNS check en live single-hop, redirects en browseInSession con jar por host + prune por visita, sesiones 0600, docs con retención 7d/20.
L10: Second verification batch fixes: rangos 100.64/10, 192.0.0.0/24, 198.18/15, 224/4+240/4 (dotted + mapped), IPv6 punteado solo ::ffff, tests (cap 50, 303 POST→GET, tope 6 hops, 0600), docs known limits (TOCTOU, host-wide cookies). Focos 47/47 + nim check exit 0; re-verify mwnplhb9-5-t1og pendiente.
L11: Re-verify mwnpwe6x-1-71ts: 47/47 PASS + nim check exit 0; residuals: save no atomico, adapt fallback solo tests. Cierre: tests de rangos mapeados + nota save no atomico en benchmarks. Focos 48/48 (23+15+10). Sin commits (usuario no pidio).
