#include "elf64/internal_fix.h"

#include <stddef.h>
#include <string.h>

char const *get_section_name(elf_section_header const *section)
{
    char const *name = NULL;

    switch (section->type)
    {
        case S_NULL:
            name = "";
            break;
        case S_PROGBITS:
            name = section->data.s_progbits.section_name;
            break;
        case S_RELA:
            name = section->data.s_rela.section_name;
            break;
        case S_NOBITS:
            name = section->data.s_nobits.section_name;
            break;
        case S_SYMTAB:
            name = section->data.s_symtab.section_name;
            break;
        case S_STRTAB:
            name = section->data.s_strtab.section_name;
            break;
    }

    return name;
}

int find_section_index_by_name(elf_section_header const **sections, unsigned int size, char const *name)
{
    int index = -1;
    int i = 0;

    while (index == -1 && i < size)
    {
        char const *section_name = get_section_name(sections[i]);
        if (strcmp(section_name, name) == 0) index = i;
        i++;
    }

    return index;
}