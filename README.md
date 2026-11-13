# MacCap

Capturas de pantalla desde la barra de menús de macOS, sin tener que recordar combinaciones de teclas.
Un icono en la barra de menús (arriba a la derecha) reúne todas las opciones y añade lo que macOS no trae de serie:
un editor para dibujar rectángulos, flechas, texto, números, pixelar, resaltar… y copiar texto de cualquier zona (OCR).

## Descarga

Cada push a `main` compila la app con GitHub Actions y la publica en la release **latest**:

- [**MacCap.dmg**](https://github.com/SrCrowder/mac-cap/releases/download/latest/MacCap.dmg) (o `MacCap.zip`) en la página de [Releases](https://github.com/SrCrowder/mac-cap/releases).
- También como *artifact* en cada ejecución de [Actions](https://github.com/SrCrowder/mac-cap/actions).
- Al subir una etiqueta `v*` (p. ej. `git tag v1.0 && git push --tags`) se crea una release con versión (también sirve como actualización).

La app es universal (Apple Silicon e Intel) y necesita macOS 12 o posterior.

### Primer arranque

La app no está firmada con un certificado de Apple Developer, así que la primera vez macOS la bloquea:

1. Abre el `.dmg` y arrastra **MacCap** a **Aplicaciones**.
2. Abre MacCap. Si macOS dice que no se puede verificar, ve a **Ajustes del Sistema → Privacidad y seguridad**
   y pulsa **Abrir igualmente** (o, desde Terminal: `xattr -dr com.apple.quarantine /Applications/MacCap.app`).
3. Concede **Grabación de pantalla** a MacCap cuando lo pida (**Privacidad y seguridad → Grabación de pantalla**)
   y vuelve a abrir la app. Si falta el permiso, el menú muestra un aviso para abrir esos ajustes.

### Actualizaciones automáticas

MacCap se actualiza sola con [Sparkle](https://sparkle-project.org): busca versiones nuevas al arrancar y una vez al
día, avisa con las novedades y se instala y reinicia con un clic. También puedes usar **Buscar actualizaciones…** en
el menú, o activar **Opciones → Instalar actualizaciones sin preguntar** para que lo haga en segundo plano.

Cómo funciona por dentro:

- Cada push a `main` publica en la release `latest` el `MacCap.zip` y un `appcast.xml` (el canal de actualizaciones),
  con la versión `1.1.<número de ejecución>`.
- El zip va firmado con una clave Ed25519 (secreto `SPARKLE_ED_PRIVATE_KEY`); la app solo instala actualizaciones cuya
  firma coincide con la clave pública de `Info.plist` (`SUPublicEDKey`).
- La app se firma siempre con el mismo certificado autofirmado (secretos `MACOS_CERT_P12` y `MACOS_CERT_PASSWORD`), así
  que macOS la reconoce como la misma app y **conserva el permiso de grabación de pantalla** entre versiones.

Las versiones anteriores a la 1.1.12 no incluyen el actualizador: instálala a mano una vez más y desde ahí se
actualizará sola (puede que pida el permiso de grabación de pantalla esa última vez).

## Qué hace

Haz clic en el icono de la barra de menús:

| Sección | Opciones |
| --- | --- |
| **Copiar al portapapeles** | Zona · Ventana · Pantalla completa |
| **Guardar en archivo** | Zona · Ventana · Pantalla completa (PNG, JPG o HEIC en el Escritorio o la carpeta que elijas) |
| **Anotar** | Zona, ventana o pantalla completa y abrir el editor · Anotar la imagen del portapapeles o de un archivo |
| **Extras** | Copiar texto de una zona (OCR) · Leer código QR · Fijar zona en pantalla · Cuentagotas |
| **Grabar y medir** | Grabar zona en MP4 · Grabar zona como GIF · Captura con scroll · Regla · Herramienta nativa de macOS |
| **Recientes** | Las últimas 20 capturas: copiar, anotar, fijar, guardar o mostrar en Finder |
| **Opciones** | Retardo · Cursor · Sombra · Sonido · Formato · Carpeta · Miniatura · Historial · Atajos · Idioma · Inicio de sesión · Actualizaciones |

En zona: arrastra para seleccionar, **espacio** cambia a modo ventana y **Esc** cancela.

- **Miniatura flotante:** tras copiar o guardar aparece una vista previa en la esquina. Clic para anotar,
  arrástrala a otra app (Slack, Mail, Finder…), o usa sus botones para copiar, fijar o descartar.
- **Fijar en pantalla:** la imagen flota encima de todo como referencia. Arrastra para moverla, bordes para
  redimensionar, clic derecho para copiar, anotar o cambiar la opacidad, **Esc** para cerrar.
- **Cuentagotas:** haz clic en cualquier píxel y se copia su color en hexadecimal (`#RRGGBB`).
- **QR:** selecciona la zona con el código; el contenido se copia y, si es un enlace, ofrece abrirlo.
- **Grabar zona (MP4/GIF):** elige la zona y pulsa **Detener** en el panel (o en el menú). Se guarda en la carpeta
  de capturas. Las ventanas de MacCap no salen en la grabación.
- **Captura con scroll:** elige la zona que se desplaza (el contenido de la página) y baja **despacio**; al pulsar
  **Terminar** se abre la imagen completa en el editor. Si avisa «Más despacio…», vuelve un poco hacia arriba.
- **Regla:** arrastra para medir en puntos y píxeles; **Mayús** para solo horizontal/vertical, **Esc** para salir.

### Atajos de teclado

Todas las acciones pueden tener atajo global: **Opciones → Configurar atajos…** Por defecto:

| Atajo | Acción |
| --- | --- |
| ⇧⌘7 | Capturar zona y anotar |
| ⇧⌘8 | Capturar zona y copiar |
| ⇧⌘9 | Copiar texto de una zona (OCR) |

### Editor de anotaciones

Herramientas (con su tecla): **V** seleccionar y mover · **R** rectángulo · **O** elipse · **A** flecha ·
**L** línea · **P** lápiz · **H** resaltador · **T** texto · **N** números (1, 2, 3…) · **B** pixelar ·
**D** difuminar · **C** recortar.

- **Seleccionar (V):** haz clic en una anotación para moverla; arrastra sus puntos para redimensionar formas,
  flechas y líneas; cambia su color o grosor con la barra; **Supr** la borra.
- 8 colores y 3 grosores. **Mayús** al arrastrar hace cuadrados/círculos y líneas a 45°.
- **Recortar (C):** arrastra la zona que quieres conservar (⌘Z lo deshace).
- **Fondo:** añade margen, degradado, esquinas redondeadas y sombra para compartir.
- **Pixelar** y **difuminar** ocultan el contenido de forma que no se puede recuperar.
- **⌘Z / ⇧⌘Z** deshacer y rehacer, papelera para borrar todo.
- **⌘C** copia, **⌘S** guarda, **⌘↩** copia y cierra. Si cierras sin copiar ni guardar, pregunta antes.
- La imagen se exporta a resolución completa (Retina incluida).

### Idioma

Español o inglés según el sistema, o el que elijas en **Opciones → Idioma**.

## Compilar en local

Necesitas Xcode o las Command Line Tools (`xcode-select --install`).

```sh
./build-app.sh          # crea build/MacCap.app (universal)
open build/MacCap.app
swift test              # pruebas
```

`MACCAP_NATIVE_ONLY=1 ./build-app.sh` compila solo para la arquitectura del Mac (más rápido).
