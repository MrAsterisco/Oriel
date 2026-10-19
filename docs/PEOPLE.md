# People

People scans supported still pictures recursively under the window’s authorized root. It uses the same media enumeration as Recents, including its exclusion of hidden folders, packages, and symbolic-link directories. It never modifies pictures.

`MediaBrowserFeatureModel` owns each window’s scan lifecycle, gallery, album selection, and errors. `PeopleRepository` owns grouping and session caches; `FaceRecognitionRepository` owns image reads, Apple Vision face landmarks, alignment, and Core ML inference. Factory constructs all dependencies. File mutations and normal picture viewing continue through the existing repositories.

Pictures are first scanned in ascending relative-path order; faces within a photo are ordered left to right. A new group takes its name from that photo’s immediate parent folder (or the root’s display name). Multiple people from the same folder may therefore have the same display name. Session-local group identities and names survive rescans, including removal of their original photo. Only groups with current photos are returned. No face data is persisted to disk by Oriel.

Each detected face is aligned using eye centers and mouth corners, then encoded as a normalized 128-dimensional SFace embedding. Each person keeps the individual reference faces, with one reference per photo. References are never averaged into a centroid or a group-wide score. Repeated scans replace a photo’s reference rather than counting it again.

Matching ranks groups by their strongest individual cosine match. A confident match of at least 0.6 can establish another pose on its own. Moderate matches use SFace’s upstream 0.363 cutoff and require corroboration from at least two reference photos. An isolated moderate pair waits for the final reconciliation pass, where stronger pairs are processed first; it cannot claim a photo prematurely during discovery.

After scanning, split groups are reconciled using the same individual-reference evidence. A confident cross-group pair is sufficient. Otherwise, moderate matches must involve at least two different reference photos on each side that has multiple references. Two singleton groups may bootstrap from one moderate pair during this ordered pass. Groups containing distinct faces from the same photo cannot merge. Candidate merges are revisited after merges add supporting references, until no eligible merge remains. Accelerate computes the individual vector comparisons.

Each merge preserves the earlier-discovered group’s identity, folder-derived name, and portrait. The gallery removes retired cards, and an open retired album follows the surviving group while retaining its current photo and selection. Reconciliation happens when the scan finishes, so partial results can temporarily contain split entries.

Photos with multiple people appear once in each applicable album. Recognition is probabilistic: small, obscured, profile, and otherwise difficult faces may still be missed, split, or incorrectly matched. There is no manual naming, merge, or correction flow.

Unchanged picture metadata reuses cached detections, including no-face results. File changes queue a fresh scan; partial results appear while it runs. A failed scan reports an error and can be retried. Closing the window cancels its scan. Caches are in memory for the app session, and all processing is local. There are no network calls or runtime model downloads in this feature.

Duplicate and People scans run at background priority. Vision requests prefer background processing, and SFace uses the CPU and Neural Engine to leave the GPU available for rendering. Incremental results are published at most four times per second, with complete results always published at the end. If the enumerated pictures and their metadata are unchanged, a completed scan is reused without repeating image analysis or face grouping. Duplicate scans check the existing pixel-agreement rules before requesting Vision feature prints, so distinct pictures can skip that inference entirely. These scheduling choices prioritize browsing responsiveness over scan completion time.

## Search by reference image

**Search for person** in People opens the system image picker. `PeopleRepository.referenceFaces` temporarily accesses the selected image, detects its faces, and releases access after reading. The reference is neither copied into the root nor persisted. A single face starts searching automatically; an image with multiple faces presents accessible face buttons so the user chooses one. Images without a recognizable face and unreadable images report an error and allow another selection.

`PeopleRepository.pictures(matching:in:)` recursively queries all supported still pictures through `MediaRepository`, using the same metadata-keyed face cache as album discovery. It compares the selected reference directly with each detected face using normalized cosine similarity and the existing 0.363 SFace cutoff. A photo appears once when any face matches. Search does not expand matches through person groups, average references, or require an existing album. Results stream in relative-path order without an age or count limit. Single-reference matching is probabilistic and may miss the person or match someone else.

Each window’s feature model owns its transient reference, selected face, results, progress, and errors. Search results reuse the media browser and viewer, including selection, keyboard navigation, looping, context menus, and mutations. File changes and successful mutations rerun the search; existing results and selection remain until the replacement scan completes. Failures report an error and allow retry. Choosing another reference or face cancels the old query and clears its selection. Leaving search or closing the window cancels outstanding work, and stale results cannot change another destination.

## Bundled model

- Source: [OpenCV Zoo SFace](https://huggingface.co/opencv/opencv_zoo/tree/main/models/face_recognition_sface), `face_recognition_sface_2021dec.onnx`.
- Original model SHA-256: `0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79`.
- [Upstream model documentation and license statement](https://huggingface.co/opencv/opencv_zoo/blob/main/models/face_recognition_sface/README.md).
- License: Apache 2.0, bundled in `Oriel/Oriel/Resources/SFace-LICENSE.txt`. Copyright (C) 2021, Shenzhen Institute of Artificial Intelligence and Robotics for Society. SFace is contributed by Yaoyao Zhong; ONNX conversion by Chengrui Wang.
- Oriel modification: converted to Core ML with Float16 weights, named image/embedding inputs and outputs, and RGB preprocessing folded into the image input. The bundled model is approximately 19 MB; Xcode compiles and packages it for all supported Apple platforms.

To reproduce the conversion, install `coremltools==8.3.0` and `onnx==1.17.0` in a temporary Python 3.12 environment. Download the original ONNX file, then run `python scripts/convert_sface.py /path/to/face_recognition_sface_2021dec.onnx`. The script checks the source checksum before conversion. It is a development tool; Python and ONNX are not app dependencies.

Validation covers the reproduced failure where one reference scores 0.766 but averaging all poses scores only 0.147, for both assignment and reconciliation. Tests also cover first-discovered names and identities, co-occurring faces, weak chains, deferred moderate pairs, reference replacement on rescans, and keeping an open album and selection through a merge. Recursive refresh, model loading/inference, alignment geometry, failure/retry, and cancellation tests also run.

## Public-photo validation

The opt-in `PeopleCorpusValidationTests` test runs the actual Vision and bundled Core ML pipeline on 61 public photos with 13 identities explicitly labelled by DeepFace’s verification CSVs, pinned to [source commit 7cc7afcd469645b70881a56d3d96d88902d24212](https://github.com/serengil/deepface/tree/7cc7afcd469645b70881a56d3d96d88902d24212/tests/unit/dataset). It then tests ten deterministic photo orders: sorted, reversed, and eight rotations. All 61 photos produced one detected face; all ten orders produced 13 groups with no mixed identities or split identities on this corpus. This validates these public examples, not an accuracy guarantee for arbitrary photo libraries.

To reproduce in a new temporary directory:

```sh
python3 scripts/prepare_people_validation.py /tmp/oriel-people-corpus
TEST_RUNNER_ORIEL_PEOPLE_CORPUS=/tmp/oriel-people-corpus xcodebuild \
  -project Oriel/Oriel.xcodeproj -scheme Oriel -destination 'platform=macOS' \
  -derivedDataPath /tmp/oriel-people-validation \
  -only-testing:OrielTests/PeopleCorpusValidationTests test
```

The preparer checks that positive and negative labels agree and that the pinned corpus contains 61 photos and 13 identities. It downloads public development fixtures only, into the requested new directory. Normal tests skip this opt-in test, and the app never downloads or bundles these photos. The benchmark writes its diagnostic report and embeddings to the test host’s temporary directory, outside the repository; Oriel’s feature does not persist embeddings.

The same suite compares duplicate groups with an eager Vision baseline and writes diagnostic timings for eager, pixel-first, and unchanged scans to `oriel-scan-performance.json` in the test host’s temporary directory. Timing is not a pass/fail criterion; matching results must agree.

The Core ML conversion was separately compared with the original ONNX model on three generated RGB inputs (cosine agreement above 0.9999).

## Image memory

Face detections and People groups retain embeddings and versioned image references with alignment transforms, not decoded face images. Visible People cards and reference-face choices load their 112 × 112 crops through the feature model and repositories, releasing their view state on disappearance. Recognition keeps a separate cache of at most 128 decoded crops (6.125 MiB of pixel data); eviction regenerates a crop from its source without rerunning recognition. A rescan refreshes a group's representative image from a surviving photo while preserving its name and identity.

The media repository uses a separate decoded-image cache capped at 64 MiB and 256 entries. Oversized viewer images are displayed without entering that cache. Mac collection cells release their hosted images when they leave display or enter reuse, and thumbnail updates visit only visible section headers.
