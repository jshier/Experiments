// llhttp-verdicts FILE...: llhttp's verdict on the first request in each file (llhttp v9.4.4 from the llhttp set, strict
// settings, no lenient flags), one TSV line per file: name, verdict, offset.
//   accept   on_message_complete ran: offset is where the message ended
//   reject   llhttp_execute returned an error first: offset is where (error position)
//   partial  neither: the input ended first (offset -1)
// Built and run by make-corpus.sh, for HTTPBytes' H2OCorpusBulkTests.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "llhttp.h"

static int on_message_complete(llhttp_t *parser) {
    *(int *)parser->data = 1;
    return HPE_PAUSED;
}

int main(int argc, char **argv) {
    llhttp_settings_t settings;
    llhttp_settings_init(&settings);
    settings.on_message_complete = on_message_complete;
    for (int i = 1; i < argc; i++) {
        FILE *file = fopen(argv[i], "rb");
        if (!file) { perror(argv[i]); return 1; }
        fseek(file, 0, SEEK_END);
        long size = ftell(file);
        fseek(file, 0, SEEK_SET);
        char *bytes = malloc(size > 0 ? size : 1);
        if (fread(bytes, 1, size, file) != (size_t)size) { perror(argv[i]); return 1; }
        fclose(file);
        llhttp_t parser;
        int complete = 0;
        llhttp_init(&parser, HTTP_REQUEST, &settings);
        parser.data = &complete;
        llhttp_errno_t error = llhttp_execute(&parser, bytes, size);
        const char *name = strrchr(argv[i], '/') ? strrchr(argv[i], '/') + 1 : argv[i];
        if (error == HPE_PAUSED && complete) {
            printf("%s\taccept\t%ld\n", name, (long)(llhttp_get_error_pos(&parser) - bytes));
        } else if (error != HPE_OK) {
            printf("%s\treject\t%ld\t%s\n", name, (long)(llhttp_get_error_pos(&parser) - bytes), llhttp_errno_name(error));
        } else {
            printf("%s\tpartial\t-1\n", name);
        }
        free(bytes);
    }
    return 0;
}
