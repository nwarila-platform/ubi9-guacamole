#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        const char *error = dlerror();
        fprintf(stderr, "dlopen failed: %s\n", error ? error : "unknown error");
        return 1;
    }
    dlclose(handle);
    return 0;
}
