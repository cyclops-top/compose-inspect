#include <android/bitmap.h>
#include <jni.h>
#include <zlib.h>
#include <cstdint>
#include <cstring>
#include <vector>

// Bench-only lossless path for opaque sRGB RGBA_8888 windows. Other inputs fall back.
namespace {
void word(std::vector<uint8_t>& out, uint32_t n) {
    for (int shift = 24; shift >= 0; shift -= 8) out.push_back(n >> shift);
}
void chunk(std::vector<uint8_t>& out, const char* name, const uint8_t* data, size_t size) {
    word(out, size);
    const auto start = out.size();
    out.insert(out.end(), name, name + 4);
    if (size) out.insert(out.end(), data, data + size);
    word(out, crc32(0, out.data() + start, size + 4));
}
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_composeinspect_sdk_FastPng_encode(JNIEnv* env, jobject, jobject bitmap) {
    AndroidBitmapInfo info{};
    if (AndroidBitmap_getInfo(env, bitmap, &info) || info.format != ANDROID_BITMAP_FORMAT_RGBA_8888 ||
        !info.width || !info.height || uint64_t(info.width) * info.height > 16000000) return nullptr;
    const size_t rowSize = 1 + size_t(info.width) * 3;
    std::vector<uint8_t> scan(rowSize * info.height);
    void* address = nullptr;
    if (AndroidBitmap_lockPixels(env, bitmap, &address)) return nullptr;
    bool opaque = true;
    for (size_t y = 0; y < info.height && opaque; ++y) {
        auto* src = static_cast<const uint8_t*>(address) + y * info.stride;
        auto* dst = scan.data() + y * rowSize;
        *dst++ = 1; // PNG Sub filter
        uint8_t previous[3]{};
        for (size_t x = 0; x < info.width; ++x, src += 4) {
            if (src[3] != 255) { opaque = false; break; }
            for (int k = 0; k < 3; ++k) {
                *dst++ = src[k] - previous[k];
                previous[k] = src[k];
            }
        }
    }
    AndroidBitmap_unlockPixels(env, bitmap);
    if (!opaque) return nullptr;
    uLongf size = compressBound(scan.size());
    std::vector<uint8_t> compressed(size);
    if (compress2(compressed.data(), &size, scan.data(), scan.size(), Z_BEST_SPEED) != Z_OK) return nullptr;
    std::vector<uint8_t> out{137,80,78,71,13,10,26,10};
    std::vector<uint8_t> header;
    word(header, info.width); word(header, info.height);
    header.insert(header.end(), {8,2,0,0,0});
    chunk(out, "IHDR", header.data(), header.size());
    const uint8_t intent = 0;
    chunk(out, "sRGB", &intent, 1);
    chunk(out, "IDAT", compressed.data(), size);
    chunk(out, "IEND", nullptr, 0);
    auto result = env->NewByteArray(out.size());
    if (result) env->SetByteArrayRegion(result, 0, out.size(), reinterpret_cast<const jbyte*>(out.data()));
    return result;
}
