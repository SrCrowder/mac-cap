# MacCap

Capturas de pantalla desde la barra de menús de macOS, sin recordar combinaciones de teclas.

## Instalación

Se necesita macOS 12 o posterior y Xcode o las herramientas de línea de comandos de Xcode (`xcode-select --install`).

```sh
./build-app.sh
open build/MacCap.app
```

Opcionalmente, mueve `build/MacCap.app` a Aplicaciones. El icono de cámara aparece en la barra de menús; la aplicación no aparece en el Dock. Para iniciarla automáticamente, añádela a **Ajustes del Sistema → General → Ítems de inicio**. Usa **Salir de MacCap** para cerrarla.

macOS puede solicitar permiso de grabación de pantalla. Concédelo en **Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla** (o **Grabación de pantalla y audio del sistema**) y vuelve a abrir la aplicación si es necesario. Al compilar de nuevo la aplicación puede ser necesario revisar el permiso. Las capturas se procesan localmente.

## Uso

Haz clic en el icono para guardar como PNG o copiar al portapapeles la pantalla principal, una zona o una ventana. En las capturas interactivas, arrastra para seleccionar una zona o haz clic en la ventana; Escape cancela. Para pantallas adicionales, selecciona una zona en la pantalla deseada.

El menú permite activar un retardo de cinco segundos y, para la pantalla principal, incluir el cursor. La opción **Capturar zona y añadir rectángulos** abre un editor: arrastra sobre la imagen para dibujar rectángulos rojos, bórralos si lo necesitas y guarda o copia el resultado. Cerrar el editor descarta los cambios.

## Pruebas

```sh
swift test
```
