#include <jni.h>
#include <android/native_window_jni.h>

extern "C" JNIEXPORT jlong JNICALL
Java_io_github_dev_live2dviewer_MainActivity_getNativeWindowPtr(
    JNIEnv* env, jobject /* this */, jobject surface) {
    ANativeWindow* window = ANativeWindow_fromSurface(env, surface);
    return reinterpret_cast<jlong>(window);
}

extern "C" JNIEXPORT void JNICALL
Java_io_github_dev_live2dviewer_MainActivity_releaseNativeWindow(
    JNIEnv* /* env */, jobject /* this */, jlong ptr) {
    auto* window = reinterpret_cast<ANativeWindow*>(ptr);
    if (window != nullptr) {
        ANativeWindow_release(window);
    }
}
