# LightLabel Architecture

## System Boundaries

LightLabel is a native, offline macOS application. Its source is divided by responsibility:

- `Models` owns format-independent dataset records.
- `Annotation/Geometry` owns canonical geometry and view transforms.
- `Dataset/Importers` and `Dataset/Exporters` translate external formats.
- `Dataset/Persistence` owns atomic internal JSON writes and delayed saves.
- `Dataset/Validation` reports model consistency and geometry problems.
- `ImagePipeline` decodes images without retaining an entire dataset in memory.
- `AI` isolates Core ML/Vision output handling and post-processing.
- `App` and `Views` own user-visible state, commands, and native macOS presentation.

The domain types do not depend on SwiftUI, AppKit, YOLO, COCO, Vision, or a particular model version. This keeps imported annotations editable through one geometry model and allows exporters and inference adapters to evolve independently.

## Normalized Coordinates

`NormalizedPoint` and `BoundingBox` are the canonical internal representation. Their coordinate system is:

- Origin at the oriented image's top-left
- Positive x to the right
- Positive y downward
- Values normally in the closed range `0...1`
- Bounding boxes stored as top-left `x`, `y`, `width`, and `height`

For image dimensions `W` and `H`:

```text
pixelX = normalizedX * W
pixelY = normalizedY * H

normalizedX = pixelX / W
normalizedY = pixelY / H
```

The same formulas apply to box width and height. A YOLO detection row stores center coordinates, so import uses:

```text
left = centerX - width / 2
top  = centerY - height / 2
```

Export computes the inverse:

```text
centerX = left + width / 2
centerY = top + height / 2
```

COCO boxes are top-left-origin pixels. Import divides each x/width component by image width and each y/height component by image height. Export multiplies by the corresponding dimension. COCO and YOLO polygon vertices follow the same pixel/normalized rules.

Coordinates are not silently clamped during dataset import. Retaining invalid values lets `DatasetValidator` report out-of-bounds data. Interactive or inference boundaries may call `clamped()` when geometry must remain inside the image.

## Canvas Transform

`CanvasTransform` computes a rendered image frame inside a canvas. For aspect fit:

```text
scale = min(canvasWidth / imageWidth, canvasHeight / imageHeight)
```

Aspect fill uses `max`. The rendered frame is centered in the canvas. Conversion includes the frame's letterbox offset:

```text
canvasX = imageFrame.minX + normalizedX * imageFrame.width
canvasY = imageFrame.minY + normalizedY * imageFrame.height
```

The inverse subtracts the offset and divides by rendered width or height. SwiftUI/AppKit points and image pixels are intentionally distinct: Retina backing scale is a presentation concern and does not alter normalized annotation values. Panning and additional editor zoom should be composed at the canvas layer while `CanvasTransform` remains the image-frame conversion authority.

ImageIO thumbnail creation requests orientation transforms. Dataset dimensions and annotations must refer to the same visually oriented image; callers that add explicit rotation must update both dimensions and geometry before constructing the transform.

## Polygon Geometry

Polygon area uses the shoelace formula in normalized image space. The public area is absolute, while signed area preserves winding information. Bounds are the extrema of all points. Validation reports:

- Fewer than three points
- Non-finite values
- Coordinates outside `0...1`
- Zero or near-zero area
- Proper self-intersections

Normalized polygon area converts to pixel area by multiplying by `W * H`. Polygon bounds are used for detection-only exports and COCO `bbox` generation.

## Import And Export

### YOLO

`YOLOImporter` reads the supported `data.yaml` subset, creates stable category IDs from class index/name, discovers split image directories, reads dimensions through ImageIO, and pairs image paths with label paths. A five-value row is a detection. In automatic mode, an odd row with at least seven values is a polygon. Malformed numeric/class rows produce file-and-line warnings.

`YOLOExporter` maps category array order to zero-based class IDs. Unassigned images export to `train`. It writes one label file per image and a list-form `data.yaml`. Detection mode exports geometry bounds, including polygon bounds. Segmentation mode writes polygons and warns when boxes are skipped. Image copying is outside the current exporter.

### COCO

`COCOImporter` maps external IDs to deterministic UUIDs and converts pixel geometry using each image's dimensions. A supported polygon takes precedence over `bbox`. If segmentation contains multiple polygons, only the largest by pixel shoelace area is retained and a warning is emitted. RLE annotations are warned and skipped.

`COCOExporter` assigns sequential image and category IDs from array order, writes arrays in dataset order, and reuses an annotation source ID when available. Polygon bounds and area are recomputed. JSON keys are sorted and output is pretty-printed. Import/export preserves a defined metadata subset, not arbitrary unknown JSON.

## Stable Identity

`StableID` hashes a namespace and ordered components with fixed FNV-style arithmetic, then sets RFC 4122 version/variant bits. Importers use different namespaces for datasets, images, categories, and annotations. The same source identity produces the same UUID across runs; component order and namespace are significant. These are deterministic internal IDs, not cryptographic hashes.

## Validation

`DatasetValidator` operates on the format-independent dataset. It checks for absent categories, case-insensitive duplicate category names, invalid image dimensions, duplicate image records, missing image files when the dataset root is available, missing image/category references, invalid normalized boxes, invalid polygons, and polygons below a configurable area threshold. Corrupted content and malformed label rows are reported during import because those checks need the source bytes.

## Persistence And Autosave

`ProjectPersistence` is an actor so save scheduling and writes are serialized. It encodes `AnnotationDataset` as sorted, pretty JSON with ISO-8601 dates. Writes go to a uniquely named temporary sibling and then move or replace the destination, preventing readers from observing a partially written file. Imported datasets retain source-format metadata; each debounced application save also rewrites the original YOLO files or COCO JSON, so annotation changes do not require a manual export.

`scheduleSave` cancels the previous pending task and delays the latest snapshot, currently 350 milliseconds by default. `flushScheduledSave` waits for that snapshot and rethrows a delayed write failure. The application model uses a two-second dirty-state debounce and delegates the final atomic write through `LocalDatasetServices`.

The current persistence layer writes the complete `dataset.json`. Standard-format synchronization is performed from the saved model snapshot. Dirty-file tracking and interrupted-session recovery remain future service-layer work.

## Image Loading And Cache

`ImageLoader` is an actor with a bounded number of concurrent decode operations. Thumbnail requests use ImageIO downsampling and orientation transforms; full image requests decode only the selected image. Work runs in detached tasks so decoding does not block the main actor.

The current loader limits concurrency but does not retain an `NSCache`. A UI/service cache should be cost-bounded, keyed by standardized URL plus requested size, and should cancel obsolete navigation requests. Full-resolution images must not be preloaded for every dataset record.

## SwiftUI And AppKit Split

SwiftUI owns window composition, `NavigationSplitView`, browser modes, inspector, toolbar, menus, sheets/alerts, and observable application state. `AppModel` is main-actor isolated and delegates filesystem, validation, export, and inference work through `DatasetApplicationServices`.

AppKit is used directly for native open/save panels, `UndoManager`, and the precision `AnnotationCanvasView` hosted through `NSViewRepresentable`. The canvas handles mouse tracking, hover, key events, scroll-wheel zoom, magnification, pan, box creation/move/resize, and polygon creation/vertex editing. Completed drags expose one normalized geometry change back to SwiftUI so continuous pointer movement becomes one undo entry.

## Core ML Adapters

`ImageInferenceEngine` is the model-independent async inference boundary. `VisionCoreMLInferenceEngine` currently supports two adapters:

- Vision `[VNRecognizedObjectObservation]`: Vision boxes use a lower-left origin. Conversion to LightLabel is `top = 1 - vision.maxY`; x, width, and height are unchanged.
- A configured `RawYOLODecoder`: accepts an effective rank-two `MLMultiArray`, either candidates-by-channels or channels-by-candidates. It supports optional objectness, class scores, normalized or input-pixel coordinates, center or corner box encoding, class mapping, confidence filtering, clamping, and NMS.

Core ML exports do not have one universal tensor contract. Configuration must come from model metadata or user settings. Multi-head predictions, DFL/anchor decoding, multiple coordinated output arrays, and segmentation masks require dedicated adapters. Unsupported output throws a typed error instead of guessing.

Inference is run away from the main actor. Suggestions should remain visually and semantically distinct from confirmed manual annotations until the user accepts them.

## Privacy

No architecture component requires a server. Models and images are read from local URLs; processing uses Foundation, ImageIO, Core Graphics, Vision, and Core ML. The application has no analytics, user identity, remote model download, or telemetry path.
