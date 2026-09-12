package main

import "core:strings"

reserved_source_name :: proc(name: string) -> bool {
    return parse_type_name(name)!=.Void || name=="true" || name=="false" || name=="nil" || name=="assert" || name=="context"
}
// Raw exported names cross the language boundary. Internal names are always
// generated. Reject C/runtime collisions rather than emit broken C or inject it.
valid_export_name :: proc(name: string) -> bool {
    if len(name)==0 || name[0]=='_' || strings.has_prefix(name,"bor_") { return false }
    for ch,i in name {
        if !((ch>='a'&&ch<='z')||(ch>='A'&&ch<='Z')||ch=='_'||(i>0&&ch>='0'&&ch<='9')) { return false }
    }
    names := []string{
        "auto","break","case","char","const","continue","default","do","double","else","enum","extern","float","for","goto",
        "if","inline","int","long","register","restrict","return","short","signed","sizeof","static","struct","switch","typedef",
        "union","unsigned","void","volatile","while","bool","true","false","main","abort","exit","free","malloc","calloc","realloc",
        "abs","labs","llabs","div","ldiv","lldiv","atoi","atol","atoll","atof","strtod","strtof","strtold","strtol","strtoll",
        "strtoul","strtoull","rand","srand","atexit","getenv","system","bsearch","qsort","mblen","mbtowc","wctomb","mbstowcs","wcstombs",
        "int8_t","int16_t","int32_t","int64_t","uint8_t","uint16_t","uint32_t","uint64_t","intptr_t","uintptr_t","intmax_t","uintmax_t",
        "size_t","wchar_t","div_t","ldiv_t","lldiv_t","NULL","EXIT_SUCCESS","EXIT_FAILURE","RAND_MAX","MB_CUR_MAX",
    }
    for reserved in names { if name==reserved { return false } }
    if strings.has_prefix(name,"INT")||strings.has_prefix(name,"UINT")||strings.has_prefix(name,"BOR_")||strings.has_prefix(name,"CHAR_")||strings.has_prefix(name,"SIZE_") { return false }
    return true
}
