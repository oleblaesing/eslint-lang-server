#include "lsp.h"
#include "util.h"

int main() {
    lsp_init();
    lsp_run();
    log_info("ESLint Language Server shutting down");
    return 0;
}
