# Compose 1.12.1 metadata compatibility

The official Compose 1.12.1 inspector's relocated `kotlin-metadata-jvm` rejects Kotlin metadata 2.4.0 (maximum supported: 2.3.0). The device stack identifies `ReflectionSupport.findMappedClass` → `KotlinClassMetadata.readStrict`, including uncaught failures while reading package-level constants. Updating the host CLI's dependencies cannot repair this device-side reader.

This repair retains the exact Compose 1.12.1 inspector implementation, protocol and JNI libraries. Only `deps.ui.inspection.kotlin.metadata.*` and metadata service entries are replaced with relocated `kotlin-metadata-jvm:2.4.21`. Strict parsing remains enabled: future unsupported metadata still fails rather than silently losing fields.

## Rebuild

From the workspace root:

```sh
python3 ui-inspector/compat/build.py
./ui-inspector/build.sh
```

`build.py` verifies SHA-256 for the original Google Maven AAR, replacement Maven Central library, and dexlib2 build dependency. ASM relocates the library into the inspector's existing namespace; dexlib2 removes only the old metadata class definitions; D8 assembles the resulting DEX. Existing Android build workspace tools are used. Downloads go into `.build/metadata-compat`.

Before publishing the artifact, JVM regression tests read actual Kotlin 2.2 and 2.4 `Pair` metadata, verify property names, and confirm metadata 99.0.0 is rejected. The output ZIP uses fixed timestamps. Its SHA-256 must match `ComposeInspectorCompatibility.kt`; changing inputs requires reviewing and updating that digest.

The bundled output is `vendor/android/tools/base/ui-inspector/core/compat/compose-1.12.1-metadata-2.4.21.jar`. It is included as a core resource, so both `dump-ui` and `get-parameter` use it. Explicit `--compose-inspector` overrides take precedence. Only exact Compose 1.12.1 selects the repair; other versions retain official Maven resolution. Cache publication is atomic and verified by hash on reuse. Original downloaded inspectors are never overwritten. The distinct filename avoids reusing the original device-side class loader.

## Verification

- Core resolver tests cover exact version selection, explicit overrides, corrupted repair cache recovery, and preservation of official cache files.
- Original inspector reproduced the metadata error against `top.cyclops.oculus` on `emulator-5554` with `--include attributes,semantics,system-composables`.
- Repaired inspector successfully returned the full tree and parameters. Run the Swift `LiveInspectorTests` with explicit `COMPOSEINSPECT_*` environment variables to validate two-round capture, screenshot, import and continuation reads.

This is a version-specific repair, not a promise of compatibility with every future Compose or Kotlin version. `NOTICE.txt` and `LICENSE.txt` identify the original artifacts and their licenses; both are included in the repaired JAR.
