<p align="center">
  <img src="../screenshot.png" alt="PureMac" width="700">
</p>

<p align="center">
  <a href="../README.md">English</a> |
  <a href="README.ar.md">العربية</a> |
  <b>Español</b> |
  <a href="README.ja.md">日本語</a> |
  <a href="README.zh-Hans.md">简体中文</a> |
  <a href="README.zh-Hant.md">繁體中文</a>
</p>

<h1 align="center">PureMac</h1>

<p align="center">
  <b>Gestor de aplicaciones y limpiador de sistema para macOS, gratuito y de código abierto.</b><br>
  Desinstala apps por completo. Encuentra archivos huérfanos. Limpia la basura del sistema.<br>
  Sin suscripciones. Sin telemetría. Sin recolección de datos.
</p>

<p align="center">
  <a href="https://github.com/momenbasel/PureMac/releases/latest"><img src="https://img.shields.io/github/v/release/momenbasel/PureMac?style=flat-square&label=Descargar" alt="Última versión"></a>
  <a href="https://github.com/momenbasel/PureMac/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/momenbasel/PureMac/build.yml?style=flat-square&label=Build" alt="Estado de build"></a>
  <img src="https://img.shields.io/badge/macOS-13.0+-blue?style=flat-square" alt="macOS 13.0+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange?style=flat-square" alt="Swift 5.9">
  <a href="../LICENSE"><img src="https://img.shields.io/github/license/momenbasel/PureMac?style=flat-square" alt="Licencia MIT"></a>
  <a href="https://github.com/momenbasel/PureMac/stargazers"><img src="https://img.shields.io/github/stars/momenbasel/PureMac?style=flat-square" alt="Estrellas"></a>
  <a href="https://github.com/momenbasel/PureMac/releases"><img src="https://img.shields.io/github/downloads/momenbasel/PureMac/total?style=flat-square&label=Descargas" alt="Descargas"></a>
</p>

<p align="center">
  <a href="#instalación">Instalación</a> -
  <a href="#características">Características</a> -
  <a href="#capturas">Capturas</a> -
  <a href="#contribuir">Contribuir</a>
</p>

---

## Instalación

### Homebrew (recomendado)

```bash
brew update
brew install --cask puremac
```

### Descarga directa

Descarga el `.dmg` más reciente desde [Releases](https://github.com/momenbasel/PureMac/releases/latest), ábrelo y arrastra PureMac a `/Applications`.

> Firmado y notarizado con Apple Developer ID — se instala sin advertencias de Gatekeeper.

### Compilar desde el código fuente

```bash
brew install xcodegen
git clone https://github.com/momenbasel/PureMac.git
cd PureMac
xcodegen generate
xcodebuild -project PureMac.xcodeproj -scheme PureMac -configuration Release -derivedDataPath build build
open build/Build/Products/Release/PureMac.app
```

## Características

### Desinstalador de apps
- Descubre todas las apps instaladas desde `/Applications` y `~/Applications`
- Motor heurístico de búsqueda de archivos con **10 niveles de coincidencia** (bundle ID, nombre de la empresa, entitlements, team identifier, metadatos de Spotlight, descubrimiento de contenedores)
- **3 niveles de sensibilidad**: Estricto (seguro), Mejorado (equilibrado), Profundo (exhaustivo)
- Muestra todos los archivos relacionados: cachés, preferencias, contenedores, registros, archivos de soporte, launch agents
- Protección de apps del sistema: 27 apps de Apple están excluidas de la lista
- Vista maestro-detalle: tabla de apps a la izquierda, archivos descubiertos a la derecha

### Buscador de archivos huérfanos
- Detecta archivos sobrantes en `~/Library` de apps ya desinstaladas
- Compara el contenido de la Biblioteca con los identificadores de todas las apps instaladas
- Limpieza de archivos huérfanos con un clic

### Limpiador del sistema
- **Análisis inteligente** — análisis de un clic en todas las categorías
- **Basura del sistema** — cachés del sistema, registros y archivos temporales
- **Caché de usuario** — descubre dinámicamente todos los cachés de apps (sin lista predefinida)
- **Adjuntos de correo** — adjuntos de correo descargados
- **Papeleras** — vacía todas las papeleras
- **Archivos grandes y antiguos** — archivos de más de 100 MB o con más de 1 año
- **Espacio purgable** — detección de espacio purgable APFS
- **Basura de Xcode** — DerivedData, Archives, cachés de simuladores
- **Caché de Brew** — caché de descargas de Homebrew (detecta HOMEBREW_CACHE personalizado)
- **Limpieza programada** — análisis automático en intervalos configurables

### Experiencia nativa de macOS
- Desarrollado con SwiftUI usando componentes nativos de macOS
- `NavigationSplitView`, `Toggle`, `ProgressView`, `Form`, `GroupBox`, `Table`
- Respeta el modo claro/oscuro del sistema automáticamente
- Sin gradientes personalizados, resplandores ni estilos de app web
- Onboarding de primer arranque con configuración de acceso total al disco

### Seguridad
- Diálogos de confirmación antes de cualquier operación destructiva
- Prevención de ataques por enlaces simbólicos — resuelve y valida rutas antes de eliminar
- Protección de apps del sistema — las apps de Apple no se pueden desinstalar
- Los archivos grandes y antiguos nunca se seleccionan automáticamente
- Registro estructurado con `os.log` (visible en Consola.app)

## Capturas

| Onboarding | Desinstalador de apps |
|---|---|
| ![Onboarding](../screenshots/onboarding.png) | ![Desinstalador de apps](../screenshots/app-uninstaller.png) |

| Basura del sistema | Basura de Xcode |
|---|---|
| ![Basura del sistema](../screenshots/system-junk.png) | ![Basura de Xcode](../screenshots/xcode-junk.png) |

| Caché de usuario |
|---|
| ![Caché de usuario](../screenshots/user-cache.png) |

## Arquitectura

```
PureMac/
  Logic/Scanning/     - Motor heurístico de escaneo, base de ubicaciones, condiciones
  Logic/Utilities/    - Registro estructurado
  Models/             - Modelos de datos, errores tipados
  Services/           - Motor de escaneo, motor de limpieza, programador
  ViewModels/         - Estado centralizado de la app
  Views/              - Vistas nativas de SwiftUI
    Apps/             - Vistas del desinstalador
    Cleaning/         - Análisis inteligente y vistas de categorías
    Orphans/          - Buscador de huérfanos
    Settings/         - Ajustes basados en Form nativo
    Components/       - Componentes compartidos
```

Componentes clave:
- **AppPathFinder** — motor de coincidencia heurística de 10 niveles para descubrir archivos de apps
- **Locations** — más de 120 rutas de búsqueda del sistema de archivos macOS
- **Conditions** — 25 reglas de coincidencia por app para casos especiales (Xcode, Chrome, VS Code, etc.)
- **AppInfoFetcher** — metadatos de Spotlight + respaldo de Info.plist para descubrir apps
- **Logger** — registro unificado con `os.log` de Apple

## Contribuir

Las contribuciones son bienvenidas. Consulta [CONTRIBUTING.md](../CONTRIBUTING.md) para las pautas.

Áreas donde la ayuda es especialmente bienvenida:
- Filtros predefinidos por tamaño y fecha en las vistas de categoría
- Cobertura de XCTest para AppState y el motor de escaneo
- Localización (es, pt-BR y otros idiomas)
- Diseño del ícono de la app

## Licencia

Licencia MIT. Consulta [LICENSE](../LICENSE) para más detalles.
