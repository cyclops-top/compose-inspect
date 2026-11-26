#include <jni.h>
#include <charconv>
#include <string>
#include <vector>

// All arrays are produced inside the research APK. One JNI call per snapshot.
extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_composeinspect_research_ResearchEncoder_00024Native_encode(
        JNIEnv* env, jobject, jintArray program, jintArray index, jbyteArray dictionary) {
    std::vector<jint> words(env->GetArrayLength(program));
    std::vector<jint> offsets(env->GetArrayLength(index));
    std::string utf8(env->GetArrayLength(dictionary), '\0');
    env->GetIntArrayRegion(program, 0, words.size(), words.data());
    env->GetIntArrayRegion(index, 0, offsets.size(), offsets.data());
    env->GetByteArrayRegion(dictionary, 0, utf8.size(), reinterpret_cast<jbyte*>(utf8.data()));
    if (env->ExceptionCheck()) return nullptr;
    constexpr char punctuation[] = {0, '{', '}', '[', ']', ':', ',', 0, '\n'};
    std::string output;
    auto token = [&](jint id) {
        output.append(utf8, offsets.at(id), offsets.at(id + 1) - offsets.at(id));
    };
    auto number = [&](jint n) {
        char digits[16];
        const auto end = std::to_chars(digits, digits + sizeof(digits), n).ptr;
        output.append(digits, end);
    };
    for (size_t i = 0; i < words.size(); ++i) {
        const jint tag = words[i];
        if (tag == -9) {
            auto next = [&]() { return words.at(++i); };
            output += R"({"name":)"; token(next());
            output += R"(,"kind":)"; token(next());
            output += next() ? R"(,"inline":true)" : R"(,"inline":false)";
            output += R"(,"sourceInfo":)"; token(next());
            output += R"(,"boundsInWindow":[)"; number(next());
            for (int j = 0; j < 3; ++j) { output += ','; number(next()); }
            output += ']';
            if (next()) {
                output += R"(,"source":{)";
                const auto file = next();
                if (file >= 0) { output += R"("file":)"; token(file); output += ','; }
                output += R"("line":)"; number(next());
                output += R"(,"offset":)"; number(next());
                output += R"(,"length":)"; number(next());
                output += R"(,"packageHash":)"; number(next()); output += '}';
            }
            output += R"(,"parameters":[],"children":)";
        } else if (tag == -7) {
            number(words.at(++i));
        } else if (tag < 0) {
            output.push_back(punctuation[-tag]);
        } else {
            token(tag);
        }
    }
    auto result = env->NewByteArray(output.size());
    if (result) env->SetByteArrayRegion(result, 0, output.size(), reinterpret_cast<const jbyte*>(output.data()));
    return result;
}
