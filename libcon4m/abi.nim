## Low-level Nim wrapper for libcon4m (de5b659, 2024-07-25, "Re-implemented the 'other' literal types")
## https://github.com/crashappsec/libcon4m/commit/de5b65931a5fd3e7fa70ad4b86ba318160eae5b5
import std/atomics

const
  HATRACK_DICT_KEY_TYPE_INT* = cuint(0)
  HATRACK_DICT_KEY_TYPE_REAL* = cuint(1)
  HATRACK_DICT_KEY_TYPE_CSTR* = cuint(2)
  HATRACK_DICT_KEY_TYPE_PTR* = cuint(3)
  HATRACK_DICT_KEY_TYPE_OBJ_INT* = cuint(4)
  HATRACK_DICT_KEY_TYPE_OBJ_REAL* = cuint(5)
  HATRACK_DICT_KEY_TYPE_OBJ_CSTR* = cuint(6)
  HATRACK_DICT_KEY_TYPE_OBJ_PTR* = cuint(7)
  HATRACK_DICT_KEY_TYPE_OBJ_CUSTOM* = cuint(8)
  HATRACK_DICT_NO_CACHE* = cuint(4_294_967_295)
  FLEX_OK* = cuint(0)
  FLEX_OOB* = cuint(1)
  FLEX_UNINITIALIZED* = cuint(2)
  C4M_F_HAS_INITIALIZER* = cuint(1)
  C4M_F_DECLARED_CONST* = cuint(2)
  C4M_F_DECLARED_LET* = cuint(4)
  C4M_F_IS_DECLARED* = cuint(8)
  C4M_F_TYPE_IS_DECLARED* = cuint(16)
  C4M_F_USER_IMMUTIBLE* = cuint(32)
  C4M_F_FN_PASS_DONE* = cuint(64)
  C4M_F_USE_ERROR* = cuint(128)
  C4M_F_STATIC_STORAGE* = cuint(256)
  C4M_F_STACK_STORAGE* = cuint(512)
  C4M_F_REGISTER_STORAGE* = cuint(1024)
  C4M_F_FUNCTION_SCOPE* = cuint(2048)
  C4M_EXCEPTION_OK* = int64(0)
  C4M_EXCEPTION_IN_HANDLER* = int64(1)
  C4M_EXCEPTION_NOT_HANDLED* = int64(2)

type enum_cp_category_t* {.size: sizeof(cuint).} = enum
  UTF8PROC_CATEGORY_CN = 0
  UTF8PROC_CATEGORY_LU = 1
  UTF8PROC_CATEGORY_LL = 2
  UTF8PROC_CATEGORY_LT = 3
  UTF8PROC_CATEGORY_LM = 4
  UTF8PROC_CATEGORY_LO = 5
  UTF8PROC_CATEGORY_MN = 6
  UTF8PROC_CATEGORY_MC = 7
  UTF8PROC_CATEGORY_ME = 8
  UTF8PROC_CATEGORY_ND = 9
  UTF8PROC_CATEGORY_NL = 10
  UTF8PROC_CATEGORY_NO = 11
  UTF8PROC_CATEGORY_PC = 12
  UTF8PROC_CATEGORY_PD = 13
  UTF8PROC_CATEGORY_PS = 14
  UTF8PROC_CATEGORY_PE = 15
  UTF8PROC_CATEGORY_PI = 16
  UTF8PROC_CATEGORY_PF = 17
  UTF8PROC_CATEGORY_PO = 18
  UTF8PROC_CATEGORY_SM = 19
  UTF8PROC_CATEGORY_SC = 20
  UTF8PROC_CATEGORY_SK = 21
  UTF8PROC_CATEGORY_SO = 22
  UTF8PROC_CATEGORY_ZS = 23
  UTF8PROC_CATEGORY_ZL = 24
  UTF8PROC_CATEGORY_ZP = 25
  UTF8PROC_CATEGORY_CC = 26
  UTF8PROC_CATEGORY_CF = 27
  UTF8PROC_CATEGORY_CS = 28
  UTF8PROC_CATEGORY_CO = 29

type enum_lbreak_kind_t* {.size: sizeof(cuint).} = enum
  LB_MUSTBREAK = 0
  LB_ALLOWBREAK = 1
  LB_NOBREAK = 2

type enum_utf8proc_option_t* {.size: sizeof(cuint).} = enum
  UTF8PROC_NULLTERM = 1
  UTF8PROC_STABLE = 2
  UTF8PROC_COMPAT = 4
  UTF8PROC_COMPOSE = 8
  UTF8PROC_DECOMPOSE = 16
  UTF8PROC_IGNORE = 32
  UTF8PROC_REJECTNA = 64
  UTF8PROC_NLF2LS = 128
  UTF8PROC_NLF2PS = 256
  UTF8PROC_NLF2LF = 384
  UTF8PROC_STRIPCC = 512
  UTF8PROC_CASEFOLD = 1024
  UTF8PROC_CHARBOUND = 2048
  UTF8PROC_LUMP = 4096
  UTF8PROC_STRIPMARK = 8192
  UTF8PROC_STRIPNA = 16384

type enum_mmm_enum_t* {.size: sizeof(culong).} = enum
  HATRACK_F_RESERVATION_HELP = -9223372036854775808
  HATRACK_EPOCH_UNRESERVED = -1
  HATRACK_EPOCH_FIRST = 1

const
  HATRACK_EPOCH_MAX* = enum_mmm_enum_t.HATRACK_EPOCH_UNRESERVED
  HACK_TO_MAKE_64_BIT_mmm_enum_t* = enum_mmm_enum_t.HATRACK_EPOCH_UNRESERVED

type enum_XXH_NAMESPACEXXH_errorcode* {.size: sizeof(cuint).} = enum
  XXH_NAMESPACEXXH_OK = 0
  XXH_NAMESPACEXXH_ERROR = 1

type enum_XXH_alignment* {.size: sizeof(cuint).} = enum
  XXH_aligned = 0
  XXH_unaligned = 1

type enum_c4m_dt_kind_t* {.size: sizeof(cuint).} = enum
  C4M_DT_KIND_nil = 0
  C4M_DT_KIND_primitive = 1
  C4M_DT_KIND_internal = 2
  C4M_DT_KIND_type_var = 3
  C4M_DT_KIND_list = 4
  C4M_DT_KIND_dict = 5
  C4M_DT_KIND_tuple = 6
  C4M_DT_KIND_func = 7
  C4M_DT_KIND_box = 8
  C4M_DT_KIND_maybe = 9
  C4M_DT_KIND_object = 10
  C4M_DT_KIND_oneof = 11

type enum_c4m_builtin_type_fn* {.size: sizeof(cuint).} = enum
  C4M_BI_CONSTRUCTOR = 0
  C4M_BI_TO_STR = 1
  C4M_BI_FORMAT = 2
  C4M_BI_FINALIZER = 3
  C4M_BI_MARSHAL = 4
  C4M_BI_UNMARSHAL = 5
  C4M_BI_COERCIBLE = 6
  C4M_BI_COERCE = 7
  C4M_BI_FROM_LITERAL = 8
  C4M_BI_COPY = 9
  C4M_BI_ADD = 10
  C4M_BI_SUB = 11
  C4M_BI_MUL = 12
  C4M_BI_DIV = 13
  C4M_BI_MOD = 14
  C4M_BI_EQ = 15
  C4M_BI_LT = 16
  C4M_BI_GT = 17
  C4M_BI_LEN = 18
  C4M_BI_INDEX_GET = 19
  C4M_BI_INDEX_SET = 20
  C4M_BI_SLICE_GET = 21
  C4M_BI_SLICE_SET = 22
  C4M_BI_ITEM_TYPE = 23
  C4M_BI_VIEW = 24
  C4M_BI_CONTAINER_LIT = 25
  C4M_BI_REPR = 26
  C4M_BI_GC_MAP = 27
  C4M_BI_NUM_FUNCS = 28

type enum_c4m_ix_item_sz_t* {.size: sizeof(uint8).} = enum
  c4m_ix_item_sz_1_bit = -1
  c4m_ix_item_sz_byte = 0
  c4m_ix_item_sz_16_bits = 1
  c4m_ix_item_sz_32_bits = 2
  c4m_ix_item_sz_64_bits = 3

type enum_c4m_builtin_t* {.size: sizeof(int64).} = enum
  C4M_T_ERROR = 0
  C4M_T_VOID = 1
  C4M_T_BOOL = 2
  C4M_T_I8 = 3
  C4M_T_BYTE = 4
  C4M_T_I32 = 5
  C4M_T_CHAR = 6
  C4M_T_U32 = 7
  C4M_T_INT = 8
  C4M_T_UINT = 9
  C4M_T_F32 = 10
  C4M_T_F64 = 11
  C4M_T_UTF8 = 12
  C4M_T_BUFFER = 13
  C4M_T_UTF32 = 14
  C4M_T_GRID = 15
  C4M_T_LIST = 16
  C4M_T_TUPLE = 17
  C4M_T_DICT = 18
  C4M_T_SET = 19
  C4M_T_TYPESPEC = 20
  C4M_T_IPV4 = 21
  C4M_T_IPV6 = 22
  C4M_T_DURATION = 23
  C4M_T_SIZE = 24
  C4M_T_DATETIME = 25
  C4M_T_DATE = 26
  C4M_T_TIME = 27
  C4M_T_URL = 28
  C4M_T_FLAGS = 29
  C4M_T_CALLBACK = 30
  C4M_T_QUEUE = 31
  C4M_T_RING = 32
  C4M_T_LOGRING = 33
  C4M_T_STACK = 34
  C4M_T_RENDERABLE = 35
  C4M_T_FLIST = 36
  C4M_T_RENDER_STYLE = 37
  C4M_T_SHA = 38
  C4M_T_EXCEPTION = 39
  C4M_T_TREE = 40
  C4M_T_FUNCDEF = 41
  C4M_T_REF = 42
  C4M_T_GENERIC = 43
  C4M_T_STREAM = 44
  C4M_T_KEYWORD = 45
  C4M_T_VM = 46
  C4M_T_PARSE_NODE = 47
  C4M_T_BIT = 48
  C4M_T_BOX = 49
  C4M_T_HTTP = 50
  C4M_NUM_BUILTIN_DTS = 51

type enum_c4m_lit_syntax_t* {.size: sizeof(cuint).} = enum
  ST_Base10 = 0
  ST_Hex = 1
  ST_Float = 2
  ST_Bool = 3
  ST_2Quote = 4
  ST_1Quote = 5
  ST_List = 6
  ST_Dict = 7
  ST_Tuple = 8
  ST_MAX = 9

type enum_c4m_alignment_t* {.size: sizeof(int8).} = enum
  C4M_ALIGN_IGNORE = 0
  C4M_ALIGN_LEFT = 1
  C4M_ALIGN_RIGHT = 2
  C4M_ALIGN_CENTER = 4
  C4M_ALIGN_TOP = 8
  C4M_ALIGN_TOP_LEFT = 9
  C4M_ALIGN_TOP_RIGHT = 10
  C4M_ALIGN_TOP_CENTER = 12
  C4M_ALIGN_BOTTOM = 16
  C4M_ALIGN_BOTTOM_LEFT = 17
  C4M_ALIGN_BOTTOM_RIGHT = 18
  C4M_ALIGN_BOTTOM_CENTER = 20
  C4M_ALIGN_MIDDLE = 32
  C4M_ALIGN_MID_LEFT = 33
  C4M_ALIGN_MID_RIGHT = 34
  C4M_ALIGN_MID_CENTER = 36

type enum_c4m_dimspec_kind_t* {.size: sizeof(uint8).} = enum
  C4M_DIM_UNSET = 0
  C4M_DIM_AUTO = 1
  C4M_DIM_PERCENT_TRUNCATE = 2
  C4M_DIM_PERCENT_ROUND = 3
  C4M_DIM_FLEX_UNITS = 4
  C4M_DIM_ABSOLUTE = 5
  C4M_DIM_ABSOLUTE_RANGE = 6
  C4M_DIM_FIT_TO_TEXT = 7

type enum_c4m_u8_state_t* {.size: sizeof(cuint).} = enum
  C4M_U8_STATE_START_DEFAULT = 0
  C4M_U8_STATE_START_STYLE = 1
  C4M_U8_STATE_DEFAULT_STYLE = 2
  C4M_U8_STATE_IN_STYLE = 3

type enum_c4m_type_exact_result_t* {.size: sizeof(cuint).} = enum
  c4m_type_match_exact = 0
  c4m_type_match_left_more_specific = 1
  c4m_type_match_right_more_specific = 2
  c4m_type_match_both_have_more_generic_bits = 3
  c4m_type_cant_match = 4

type enum_c4m_party_enum* {.size: sizeof(cuint).} = enum
  C4M_PT_STRING = 1
  C4M_PT_FD = 2
  C4M_PT_LISTENER = 4
  C4M_PT_CALLBACK = 8

type enum_c4m_token_kind_t* {.size: sizeof(cuint).} = enum
  c4m_tt_error = 0
  c4m_tt_space = 1
  c4m_tt_semi = 2
  c4m_tt_newline = 3
  c4m_tt_line_comment = 4
  c4m_tt_long_comment = 5
  c4m_tt_lock_attr = 6
  c4m_tt_plus = 7
  c4m_tt_minus = 8
  c4m_tt_mul = 9
  c4m_tt_div = 10
  c4m_tt_mod = 11
  c4m_tt_lte = 12
  c4m_tt_lt = 13
  c4m_tt_gte = 14
  c4m_tt_gt = 15
  c4m_tt_neq = 16
  c4m_tt_not = 17
  c4m_tt_colon = 18
  c4m_tt_assign = 19
  c4m_tt_cmp = 20
  c4m_tt_comma = 21
  c4m_tt_period = 22
  c4m_tt_lbrace = 23
  c4m_tt_rbrace = 24
  c4m_tt_lbracket = 25
  c4m_tt_rbracket = 26
  c4m_tt_lparen = 27
  c4m_tt_rparen = 28
  c4m_tt_and = 29
  c4m_tt_or = 30
  c4m_tt_int_lit = 31
  c4m_tt_hex_lit = 32
  c4m_tt_float_lit = 33
  c4m_tt_string_lit = 34
  c4m_tt_char_lit = 35
  c4m_tt_unquoted_lit = 36
  c4m_tt_true = 37
  c4m_tt_false = 38
  c4m_tt_nil = 39
  c4m_tt_if = 40
  c4m_tt_elif = 41
  c4m_tt_else = 42
  c4m_tt_for = 43
  c4m_tt_from = 44
  c4m_tt_to = 45
  c4m_tt_break = 46
  c4m_tt_continue = 47
  c4m_tt_return = 48
  c4m_tt_enum = 49
  c4m_tt_identifier = 50
  c4m_tt_func = 51
  c4m_tt_var = 52
  c4m_tt_global = 53
  c4m_tt_const = 54
  c4m_tt_once = 55
  c4m_tt_let = 56
  c4m_tt_private = 57
  c4m_tt_backtick = 58
  c4m_tt_arrow = 59
  c4m_tt_object = 60
  c4m_tt_while = 61
  c4m_tt_in = 62
  c4m_tt_bit_and = 63
  c4m_tt_bit_or = 64
  c4m_tt_bit_xor = 65
  c4m_tt_shl = 66
  c4m_tt_shr = 67
  c4m_tt_typeof = 68
  c4m_tt_switch = 69
  c4m_tt_case = 70
  c4m_tt_plus_eq = 71
  c4m_tt_minus_eq = 72
  c4m_tt_mul_eq = 73
  c4m_tt_div_eq = 74
  c4m_tt_mod_eq = 75
  c4m_tt_bit_and_eq = 76
  c4m_tt_bit_or_eq = 77
  c4m_tt_bit_xor_eq = 78
  c4m_tt_shl_eq = 79
  c4m_tt_shr_eq = 80
  c4m_tt_lock = 81
  c4m_tt_eof = 82

type enum_c4m_compile_error_t* {.size: sizeof(cuint).} = enum
  c4m_err_open_module = 0
  c4m_err_location = 1
  c4m_err_lex_stray_cr = 2
  c4m_err_lex_eof_in_comment = 3
  c4m_err_lex_invalid_char = 4
  c4m_err_lex_eof_in_str_lit = 5
  c4m_err_lex_nl_in_str_lit = 6
  c4m_err_lex_eof_in_char_lit = 7
  c4m_err_lex_nl_in_char_lit = 8
  c4m_err_lex_extra_in_char_lit = 9
  c4m_err_lex_esc_in_esc = 10
  c4m_err_lex_invalid_float_lit = 11
  c4m_err_lex_float_oflow = 12
  c4m_err_lex_float_uflow = 13
  c4m_err_lex_int_oflow = 14
  c4m_err_parse_continue_outside_loop = 15
  c4m_err_parse_break_outside_loop = 16
  c4m_err_parse_return_outside_func = 17
  c4m_err_parse_expected_stmt_end = 18
  c4m_err_parse_unexpected_after_expr = 19
  c4m_err_parse_expected_brace = 20
  c4m_err_parse_expected_range_tok = 21
  c4m_err_parse_eof = 22
  c4m_err_parse_bad_use_uri = 23
  c4m_err_parse_id_expected = 24
  c4m_err_parse_id_member_part = 25
  c4m_err_parse_not_docable_block = 26
  c4m_err_parse_for_syntax = 27
  c4m_err_parse_missing_type_rbrak = 28
  c4m_err_parse_bad_tspec = 29
  c4m_err_parse_vararg_wasnt_last_thing = 30
  c4m_err_parse_fn_param_syntax = 31
  c4m_err_parse_enums_are_toplevel = 32
  c4m_err_parse_funcs_are_toplevel = 33
  c4m_err_parse_parameter_is_toplevel = 34
  c4m_err_parse_extern_is_toplevel = 35
  c4m_err_parse_confspec_is_toplevel = 36
  c4m_err_parse_bad_confspec_sec_type = 37
  c4m_err_parse_invalid_token_in_sec = 38
  c4m_err_parse_expected_token = 39
  c4m_err_parse_invalid_sec_part = 40
  c4m_err_parse_invalid_field_part = 41
  c4m_err_parse_no_empty_tuples = 42
  c4m_err_parse_lit_or_id = 43
  c4m_err_parse_1_item_tuple = 44
  c4m_err_parse_decl_kw_x2 = 45
  c4m_err_parse_decl_2_scopes = 46
  c4m_err_parse_decl_const_not_const = 47
  c4m_err_parse_case_else_or_end = 48
  c4m_err_parse_case_body_start = 49
  c4m_err_parse_empty_enum = 50
  c4m_err_parse_enum_item = 51
  c4m_err_parse_need_simple_lit = 52
  c4m_err_parse_need_str_lit = 53
  c4m_err_parse_need_bool_lit = 54
  c4m_err_parse_formal_expect_id = 55
  c4m_err_parse_bad_extern_field = 56
  c4m_err_parse_extern_sig_needed = 57
  c4m_err_parse_extern_bad_hold_param = 58
  c4m_err_parse_extern_bad_alloc_param = 59
  c4m_err_parse_extern_bad_prop = 60
  c4m_err_parse_extern_dup = 61
  c4m_err_parse_extern_need_local = 62
  c4m_err_parse_enum_value_type = 63
  c4m_err_parse_csig_id = 64
  c4m_err_parse_bad_ctype_id = 65
  c4m_err_parse_mod_param_no_const = 66
  c4m_err_parse_bad_param_start = 67
  c4m_err_parse_param_def_and_callback = 68
  c4m_err_parse_param_dupe_prop = 69
  c4m_err_parse_param_invalid_prop = 70
  c4m_err_parse_bad_expression_start = 71
  c4m_err_parse_missing_expression = 72
  c4m_err_parse_no_lit_mod_match = 73
  c4m_err_parse_invalid_lit_char = 74
  c4m_err_parse_lit_overflow = 75
  c4m_err_parse_lit_underflow = 76
  c4m_err_parse_lit_odd_hex = 77
  c4m_err_parse_lit_invalid_neg = 78
  c4m_err_parse_for_assign_vars = 79
  c4m_err_parse_lit_bad_flags = 80
  c4m_err_invalid_redeclaration = 81
  c4m_err_omit_string_enum_value = 82
  c4m_err_invalid_enum_lit_type = 83
  c4m_err_enum_str_int_mix = 84
  c4m_err_dupe_enum = 85
  c4m_err_unk_primitive_type = 86
  c4m_err_unk_param_type = 87
  c4m_err_no_logring_yet = 88
  c4m_err_no_params_to_hold = 89
  c4m_warn_dupe_hold = 90
  c4m_warn_dupe_alloc = 91
  c4m_err_bad_hold_name = 92
  c4m_err_bad_alloc_name = 93
  c4m_info_dupe_import = 94
  c4m_warn_dupe_require = 95
  c4m_warn_dupe_allow = 96
  c4m_warn_require_allow = 97
  c4m_err_spec_bool_required = 98
  c4m_err_spec_callback_required = 99
  c4m_warn_dupe_exclusion = 100
  c4m_err_dupe_spec_field = 101
  c4m_err_dupe_root_section = 102
  c4m_err_dupe_section = 103
  c4m_err_dupe_confspec = 104
  c4m_err_dupe_param = 105
  c4m_err_const_param = 106
  c4m_err_malformed_url = 107
  c4m_warn_no_tls = 108
  c4m_err_search_path = 109
  c4m_err_invalid_path = 110
  c4m_info_recursive_use = 111
  c4m_err_self_recursive_use = 112
  c4m_err_redecl_kind = 113
  c4m_err_no_redecl = 114
  c4m_err_redecl_neq_generics = 115
  c4m_err_spec_redef_section = 116
  c4m_err_spec_redef_field = 117
  c4m_err_spec_locked = 118
  c4m_err_dupe_validator = 119
  c4m_err_decl_mismatch = 120
  c4m_err_inconsistent_type = 121
  c4m_err_inconsistent_infer_type = 122
  c4m_err_inconsistent_item_type = 123
  c4m_err_decl_mask = 124
  c4m_warn_attr_mask = 125
  c4m_err_attr_mask = 126
  c4m_err_label_target = 127
  c4m_err_fn_not_found = 128
  c4m_err_num_params = 129
  c4m_err_calling_non_fn = 130
  c4m_err_spec_needs_field = 131
  c4m_err_field_not_spec = 132
  c4m_err_field_not_allowed = 133
  c4m_err_undefined_section = 134
  c4m_err_section_not_allowed = 135
  c4m_err_slice_on_dict = 136
  c4m_err_bad_slice_ix = 137
  c4m_err_dupe_label = 138
  c4m_err_iter_name_conflict = 139
  c4m_err_dict_one_var_for = 140
  c4m_err_future_dynamic_typecheck = 141
  c4m_err_iterate_on_non_container = 142
  c4m_warn_shadowed_var = 143
  c4m_err_unary_minus_type = 144
  c4m_err_cannot_cmp = 145
  c4m_err_range_type = 146
  c4m_err_switch_case_type = 147
  c4m_err_concrete_typeof = 148
  c4m_warn_type_overlap = 149
  c4m_warn_empty_case = 150
  c4m_err_dead_branch = 151
  c4m_err_no_ret = 152
  c4m_err_use_no_def = 153
  c4m_err_declared_incompat = 154
  c4m_err_too_general = 155
  c4m_warn_unused_param = 156
  c4m_warn_def_without_use = 157
  c4m_err_call_type_err = 158
  c4m_err_single_def = 159
  c4m_warn_unused_decl = 160
  c4m_err_global_remote_def = 161
  c4m_err_global_remote_unused = 162
  c4m_info_unused_global_decl = 163
  c4m_global_def_without_use = 164
  c4m_warn_dead_code = 165
  c4m_cfg_use_no_def = 166
  c4m_cfg_use_possible_def = 167
  c4m_cfg_return_coverage = 168
  c4m_cfg_no_return = 169
  c4m_err_const_not_provided = 170
  c4m_err_augmented_assign_to_slice = 171
  c4m_warn_cant_export = 172
  c4m_err_assigned_void = 173
  c4m_err_callback_no_match = 174
  c4m_err_callback_bad_target = 175
  c4m_err_callback_type_mismatch = 176
  c4m_err_tup_ix = 177
  c4m_err_tup_ix_bounds = 178
  c4m_warn_may_wrap = 179
  c4m_internal_type_error = 180
  c4m_err_concrete_index = 181
  c4m_err_non_dict_index_type = 182
  c4m_err_invalid_ip = 183
  c4m_err_invalid_dt_spec = 184
  c4m_err_invalid_date_spec = 185
  c4m_err_invalid_time_spec = 186
  c4m_err_invalid_size_lit = 187
  c4m_err_invalid_duration_lit = 188
  c4m_err_last = 189

type enum_c4m_err_severity_t* {.size: sizeof(cuint).} = enum
  c4m_err_severity_error = 0
  c4m_err_severity_warning = 1
  c4m_err_severity_info = 2

type enum_c4m_node_kind_t* {.size: sizeof(cuint).} = enum
  c4m_nt_error = 0
  c4m_nt_module = 1
  c4m_nt_body = 2
  c4m_nt_assign = 3
  c4m_nt_attr_set_lock = 4
  c4m_nt_cast = 5
  c4m_nt_section = 6
  c4m_nt_if = 7
  c4m_nt_elif = 8
  c4m_nt_else = 9
  c4m_nt_typeof = 10
  c4m_nt_switch = 11
  c4m_nt_for = 12
  c4m_nt_while = 13
  c4m_nt_break = 14
  c4m_nt_continue = 15
  c4m_nt_return = 16
  c4m_nt_simple_lit = 17
  c4m_nt_lit_list = 18
  c4m_nt_lit_dict = 19
  c4m_nt_lit_set = 20
  c4m_nt_lit_empty_dict_or_set = 21
  c4m_nt_lit_tuple = 22
  c4m_nt_lit_unquoted = 23
  c4m_nt_lit_callback = 24
  c4m_nt_lit_tspec = 25
  c4m_nt_lit_tspec_tvar = 26
  c4m_nt_lit_tspec_named_type = 27
  c4m_nt_lit_tspec_parameterized_type = 28
  c4m_nt_lit_tspec_func = 29
  c4m_nt_lit_tspec_varargs = 30
  c4m_nt_lit_tspec_return_type = 31
  c4m_nt_or = 32
  c4m_nt_and = 33
  c4m_nt_cmp = 34
  c4m_nt_binary_op = 35
  c4m_nt_binary_assign_op = 36
  c4m_nt_unary_op = 37
  c4m_nt_enum = 38
  c4m_nt_global_enum = 39
  c4m_nt_enum_item = 40
  c4m_nt_identifier = 41
  c4m_nt_func_def = 42
  c4m_nt_func_mods = 43
  c4m_nt_func_mod = 44
  c4m_nt_formals = 45
  c4m_nt_varargs_param = 46
  c4m_nt_member = 47
  c4m_nt_index = 48
  c4m_nt_call = 49
  c4m_nt_paren_expr = 50
  c4m_nt_variable_decls = 51
  c4m_nt_sym_decl = 52
  c4m_nt_decl_qualifiers = 53
  c4m_nt_use = 54
  c4m_nt_param_block = 55
  c4m_nt_param_prop = 56
  c4m_nt_extern_block = 57
  c4m_nt_extern_sig = 58
  c4m_nt_extern_param = 59
  c4m_nt_extern_local = 60
  c4m_nt_extern_dll = 61
  c4m_nt_extern_pure = 62
  c4m_nt_extern_holds = 63
  c4m_nt_extern_allocs = 64
  c4m_nt_extern_return = 65
  c4m_nt_label = 66
  c4m_nt_case = 67
  c4m_nt_range = 68
  c4m_nt_assert = 69
  c4m_nt_config_spec = 70
  c4m_nt_section_spec = 71
  c4m_nt_section_prop = 72
  c4m_nt_field_spec = 73
  c4m_nt_field_prop = 74
  c4m_nt_expression = 75
  c4m_nt_extern_box = 76
  c4m_nt_elided = 77

type enum_c4m_operator_t* {.size: sizeof(int64).} = enum
  c4m_op_plus = 0
  c4m_op_minus = 1
  c4m_op_mul = 2
  c4m_op_mod = 3
  c4m_op_div = 4
  c4m_op_fdiv = 5
  c4m_op_shl = 6
  c4m_op_shr = 7
  c4m_op_bitand = 8
  c4m_op_bitor = 9
  c4m_op_bitxor = 10
  c4m_op_lt = 11
  c4m_op_lte = 12
  c4m_op_gt = 13
  c4m_op_gte = 14
  c4m_op_eq = 15
  c4m_op_neq = 16

type enum_c4m_symbol_kind* {.size: sizeof(int8).} = enum
  C4M_SK_MODULE = 0
  C4M_SK_FUNC = 1
  C4M_SK_EXTERN_FUNC = 2
  C4M_SK_ENUM_TYPE = 3
  C4M_SK_ENUM_VAL = 4
  C4M_SK_ATTR = 5
  C4M_SK_VARIABLE = 6
  C4M_SK_FORMAL = 7
  C4M_SK_NUM_SYM_KINDS = 8

type enum_c4m_scope_kind* {.size: sizeof(int8).} = enum
  C4M_SCOPE_GLOBAL = 1
  C4M_SCOPE_MODULE = 2
  C4M_SCOPE_LOCAL = 4
  C4M_SCOPE_FUNC = 8
  C4M_SCOPE_FORMALS = 16
  C4M_SCOPE_ATTRIBUTES = 32
  C4M_SCOPE_IMPORTS = 64

type enum_c4m_ffi_abi* {.size: sizeof(cuint).} = enum
  C4M_FFI_FIRST_ABI = 0
  C4M_FFI_NON_GNU_ABI = 1
  C4M_FFI_GNU_ABI = 2
  C4M_FFI_LAST_ABI = 3

const C4M_FFI_DEFAULT_ABI* = enum_c4m_ffi_abi.C4M_FFI_GNU_ABI

type enum_c4m_ffi_status* {.size: sizeof(cuint).} = enum
  C4M_FFI_OK = 0
  C4M_FFI_BAD_TYPEDEF = 1
  C4M_FFI_BAD_ABI = 2
  C4M_FFI_BAD_ARGTYPE = 3

type enum_c4m_zop_t* {.size: sizeof(uint8).} = enum
  C4M_ZUAdd = -128
  C4M_ZUSub = -127
  C4M_ZUMul = -126
  C4M_ZUDiv = -125
  C4M_ZUMod = -124
  C4M_ZFAdd = -112
  C4M_ZFSub = -111
  C4M_ZFMul = -110
  C4M_ZFDiv = -109
  C4M_ZAssert = -96
  C4M_ZLockOnWrite = -80
  C4M_ZLockMutex = -79
  C4M_ZUnlockMutex = -78
  C4M_ZNot = -32
  C4M_ZAbs = -31
  C4M_ZShlI = -16
  C4M_ZSubNoPop = -15
  C4M_ZGetSign = -14
  C4M_ZBail = -2
  C4M_ZNop = -1
  C4M_ZPushConstObj = 1
  C4M_ZPushConstRef = 2
  C4M_ZPushLocalObj = 3
  C4M_ZPushLocalRef = 4
  C4M_ZPushStaticObj = 5
  C4M_ZPushStaticRef = 6
  C4M_ZPushImm = 7
  C4M_ZPushObjType = 9
  C4M_ZDupTop = 10
  C4M_ZDeref = 11
  C4M_ZLoadFromAttr = 12
  C4M_ZLoadFromView = 13
  C4M_ZPushFfiPtr = 14
  C4M_ZPushVmPtr = 15
  C4M_ZAssignAttr = 29
  C4M_ZPop = 32
  C4M_ZStoreImm = 34
  C4M_ZUnpack = 35
  C4M_ZSwap = 36
  C4M_ZAssignToLoc = 37
  C4M_ZJz = 48
  C4M_ZJnz = 49
  C4M_ZJ = 50
  C4M_ZTCall = 51
  C4M_Z0Call = 52
  C4M_ZFFICall = 53
  C4M_ZCallModule = 54
  C4M_ZRunCallback = 55
  C4M_ZSObjNew = 56
  C4M_ZBox = 62
  C4M_ZUnbox = 63
  C4M_ZTypeCmp = 64
  C4M_ZCmp = 65
  C4M_ZLt = 66
  C4M_ZULt = 67
  C4M_ZLte = 68
  C4M_ZULte = 69
  C4M_ZGt = 70
  C4M_ZUGt = 71
  C4M_ZGte = 72
  C4M_ZUGte = 73
  C4M_ZNeq = 74
  C4M_ZGteNoPop = 77
  C4M_ZCmpNoPop = 78
  C4M_ZUnsteal = 79
  C4M_ZPopToR0 = 80
  C4M_ZPushFromR0 = 81
  C4M_Z0R0c00l = 82
  C4M_ZPopToR1 = 83
  C4M_ZPushFromR1 = 84
  C4M_ZPopToR2 = 86
  C4M_ZPushFromR2 = 87
  C4M_ZPopToR3 = 89
  C4M_ZPushFromR3 = 90
  C4M_ZRet = 96
  C4M_ZModuleRet = 97
  C4M_ZHalt = 98
  C4M_ZModuleEnter = 99
  C4M_ZMoveSp = 101
  C4M_ZAdd = 112
  C4M_ZSub = 113
  C4M_ZMul = 114
  C4M_ZDiv = 115
  C4M_ZMod = 116
  C4M_ZBXOr = 117
  C4M_ZShl = 118
  C4M_ZShr = 119
  C4M_ZBOr = 120
  C4M_ZBAnd = 121
  C4M_ZBNot = 122

type enum_c4m_attr_status_t* {.size: sizeof(cuint).} = enum
  c4m_attr_invalid = 0
  c4m_attr_field = 1
  c4m_attr_user_def_field = 2
  c4m_attr_object_type = 3
  c4m_attr_singleton = 4
  c4m_attr_instance = 5

type enum_c4m_attr_error_t* {.size: sizeof(cuint).} = enum
  c4m_attr_no_error = 0
  c4m_attr_err_sec_under_field = 1
  c4m_attr_err_field_not_allowed = 2
  c4m_attr_err_no_such_sec = 3
  c4m_attr_err_sec_not_allowed = 4

type enum_c4m_cfg_node_type* {.size: sizeof(cuint).} = enum
  c4m_cfg_block_entrance = 0
  c4m_cfg_block_exit = 1
  c4m_cfg_node_branch = 2
  c4m_cfg_use = 3
  c4m_cfg_def = 4
  c4m_cfg_call = 5
  c4m_cfg_jump = 6

type enum_c4m_module_compile_status* {.size: sizeof(cuint).} = enum
  c4m_compile_status_struct_allocated = 0
  c4m_compile_status_tokenized = 1
  c4m_compile_status_code_parsed = 2
  c4m_compile_status_code_loaded = 3
  c4m_compile_status_scopes_merged = 4
  c4m_compile_status_tree_typed = 5
  c4m_compile_status_applied_folding = 6
  c4m_compile_status_generated_code = 7

type enum_c4m_file_kind* {.size: sizeof(cint).} = enum
  C4M_FK_OTHER = -1
  C4M_FK_NOT_FOUND = 0
  C4M_FK_IS_FIFO = 4096
  C4M_FK_IS_CHR_DEVICE = 8192
  C4M_FK_IS_DIR = 16384
  C4M_FK_IS_BLOCK_DEVICE = 24576
  C4M_FK_IS_REG_FILE = 32768
  C4M_FK_IS_FLINK = 40960
  C4M_FK_IS_SOCK = 49152
  C4M_FK_IS_DLINK = 57344

type enum_c4m_http_method_t* {.size: sizeof(cuint).} = enum
  c4m_http_get = 0
  c4m_http_header = 1
  c4m_http_post = 2

type enum_CURLcode* {.size: sizeof(cuint).} = enum
  CURLE_OK = 0
  CURLE_UNSUPPORTED_PROTOCOL = 1
  CURLE_FAILED_INIT = 2
  CURLE_URL_MALFORMAT = 3
  CURLE_NOT_BUILT_IN = 4
  CURLE_COULDNT_RESOLVE_PROXY = 5
  CURLE_COULDNT_RESOLVE_HOST = 6
  CURLE_COULDNT_CONNECT = 7
  CURLE_WEIRD_SERVER_REPLY = 8
  CURLE_REMOTE_ACCESS_DENIED = 9
  CURLE_FTP_ACCEPT_FAILED = 10
  CURLE_FTP_WEIRD_PASS_REPLY = 11
  CURLE_FTP_ACCEPT_TIMEOUT = 12
  CURLE_FTP_WEIRD_PASV_REPLY = 13
  CURLE_FTP_WEIRD_227_FORMAT = 14
  CURLE_FTP_CANT_GET_HOST = 15
  CURLE_HTTP2 = 16
  CURLE_FTP_COULDNT_SET_TYPE = 17
  CURLE_PARTIAL_FILE = 18
  CURLE_FTP_COULDNT_RETR_FILE = 19
  CURLE_OBSOLETE20 = 20
  CURLE_QUOTE_ERROR = 21
  CURLE_HTTP_RETURNED_ERROR = 22
  CURLE_WRITE_ERROR = 23
  CURLE_OBSOLETE24 = 24
  CURLE_UPLOAD_FAILED = 25
  CURLE_READ_ERROR = 26
  CURLE_OUT_OF_MEMORY = 27
  CURLE_OPERATION_TIMEDOUT = 28
  CURLE_OBSOLETE29 = 29
  CURLE_FTP_PORT_FAILED = 30
  CURLE_FTP_COULDNT_USE_REST = 31
  CURLE_OBSOLETE32 = 32
  CURLE_RANGE_ERROR = 33
  CURLE_HTTP_POST_ERROR = 34
  CURLE_SSL_CONNECT_ERROR = 35
  CURLE_BAD_DOWNLOAD_RESUME = 36
  CURLE_FILE_COULDNT_READ_FILE = 37
  CURLE_LDAP_CANNOT_BIND = 38
  CURLE_LDAP_SEARCH_FAILED = 39
  CURLE_OBSOLETE40 = 40
  CURLE_FUNCTION_NOT_FOUND = 41
  CURLE_ABORTED_BY_CALLBACK = 42
  CURLE_BAD_FUNCTION_ARGUMENT = 43
  CURLE_OBSOLETE44 = 44
  CURLE_INTERFACE_FAILED = 45
  CURLE_OBSOLETE46 = 46
  CURLE_TOO_MANY_REDIRECTS = 47
  CURLE_UNKNOWN_OPTION = 48
  CURLE_SETOPT_OPTION_SYNTAX = 49
  CURLE_OBSOLETE50 = 50
  CURLE_OBSOLETE51 = 51
  CURLE_GOT_NOTHING = 52
  CURLE_SSL_ENGINE_NOTFOUND = 53
  CURLE_SSL_ENGINE_SETFAILED = 54
  CURLE_SEND_ERROR = 55
  CURLE_RECV_ERROR = 56
  CURLE_OBSOLETE57 = 57
  CURLE_SSL_CERTPROBLEM = 58
  CURLE_SSL_CIPHER = 59
  CURLE_PEER_FAILED_VERIFICATION = 60
  CURLE_BAD_CONTENT_ENCODING = 61
  CURLE_OBSOLETE62 = 62
  CURLE_FILESIZE_EXCEEDED = 63
  CURLE_USE_SSL_FAILED = 64
  CURLE_SEND_FAIL_REWIND = 65
  CURLE_SSL_ENGINE_INITFAILED = 66
  CURLE_LOGIN_DENIED = 67
  CURLE_TFTP_NOTFOUND = 68
  CURLE_TFTP_PERM = 69
  CURLE_REMOTE_DISK_FULL = 70
  CURLE_TFTP_ILLEGAL = 71
  CURLE_TFTP_UNKNOWNID = 72
  CURLE_REMOTE_FILE_EXISTS = 73
  CURLE_TFTP_NOSUCHUSER = 74
  CURLE_OBSOLETE75 = 75
  CURLE_OBSOLETE76 = 76
  CURLE_SSL_CACERT_BADFILE = 77
  CURLE_REMOTE_FILE_NOT_FOUND = 78
  CURLE_SSH = 79
  CURLE_SSL_SHUTDOWN_FAILED = 80
  CURLE_AGAIN = 81
  CURLE_SSL_CRL_BADFILE = 82
  CURLE_SSL_ISSUER_ERROR = 83
  CURLE_FTP_PRET_FAILED = 84
  CURLE_RTSP_CSEQ_ERROR = 85
  CURLE_RTSP_SESSION_ERROR = 86
  CURLE_FTP_BAD_FILE_LIST = 87
  CURLE_CHUNK_FAILED = 88
  CURLE_NO_CONNECTION_AVAILABLE = 89
  CURLE_SSL_PINNEDPUBKEYNOTMATCH = 90
  CURLE_SSL_INVALIDCERTSTATUS = 91
  CURLE_HTTP2_STREAM = 92
  CURLE_RECURSIVE_API_CALL = 93
  CURLE_AUTH_ERROR = 94
  CURLE_HTTP3 = 95
  CURLE_QUIC_CONNECT_ERROR = 96
  CURLE_PROXY = 97
  CURLE_SSL_CLIENTCERT = 98
  CURLE_UNRECOVERABLE_POLL = 99
  CURLE_TOO_LARGE = 100
  CURLE_ECH_REQUIRED = 101
  CURL_LAST = 102

type enum_CURLoption* {.size: sizeof(cuint).} = enum
  CURLOPT_PORT = 3
  CURLOPT_TIMEOUT = 13
  CURLOPT_INFILESIZE = 14
  CURLOPT_LOW_SPEED_LIMIT = 19
  CURLOPT_LOW_SPEED_TIME = 20
  CURLOPT_RESUME_FROM = 21
  CURLOPT_CRLF = 27
  CURLOPT_SSLVERSION = 32
  CURLOPT_TIMECONDITION = 33
  CURLOPT_TIMEVALUE = 34
  CURLOPT_VERBOSE = 41
  CURLOPT_HEADER = 42
  CURLOPT_NOPROGRESS = 43
  CURLOPT_NOBODY = 44
  CURLOPT_FAILONERROR = 45
  CURLOPT_UPLOAD = 46
  CURLOPT_POST = 47
  CURLOPT_DIRLISTONLY = 48
  CURLOPT_APPEND = 50
  CURLOPT_NETRC = 51
  CURLOPT_FOLLOWLOCATION = 52
  CURLOPT_TRANSFERTEXT = 53
  CURLOPT_PUT = 54
  CURLOPT_AUTOREFERER = 58
  CURLOPT_PROXYPORT = 59
  CURLOPT_POSTFIELDSIZE = 60
  CURLOPT_HTTPPROXYTUNNEL = 61
  CURLOPT_SSL_VERIFYPEER = 64
  CURLOPT_MAXREDIRS = 68
  CURLOPT_FILETIME = 69
  CURLOPT_MAXCONNECTS = 71
  CURLOPT_OBSOLETE72 = 72
  CURLOPT_FRESH_CONNECT = 74
  CURLOPT_FORBID_REUSE = 75
  CURLOPT_CONNECTTIMEOUT = 78
  CURLOPT_HTTPGET = 80
  CURLOPT_SSL_VERIFYHOST = 81
  CURLOPT_HTTP_VERSION = 84
  CURLOPT_FTP_USE_EPSV = 85
  CURLOPT_SSLENGINE_DEFAULT = 90
  CURLOPT_DNS_USE_GLOBAL_CACHE = 91
  CURLOPT_DNS_CACHE_TIMEOUT = 92
  CURLOPT_COOKIESESSION = 96
  CURLOPT_BUFFERSIZE = 98
  CURLOPT_NOSIGNAL = 99
  CURLOPT_PROXYTYPE = 101
  CURLOPT_UNRESTRICTED_AUTH = 105
  CURLOPT_FTP_USE_EPRT = 106
  CURLOPT_HTTPAUTH = 107
  CURLOPT_FTP_CREATE_MISSING_DIRS = 110
  CURLOPT_PROXYAUTH = 111
  CURLOPT_SERVER_RESPONSE_TIMEOUT = 112
  CURLOPT_IPRESOLVE = 113
  CURLOPT_MAXFILESIZE = 114
  CURLOPT_USE_SSL = 119
  CURLOPT_TCP_NODELAY = 121
  CURLOPT_FTPSSLAUTH = 129
  CURLOPT_IGNORE_CONTENT_LENGTH = 136
  CURLOPT_FTP_SKIP_PASV_IP = 137
  CURLOPT_FTP_FILEMETHOD = 138
  CURLOPT_LOCALPORT = 139
  CURLOPT_LOCALPORTRANGE = 140
  CURLOPT_CONNECT_ONLY = 141
  CURLOPT_SSL_SESSIONID_CACHE = 150
  CURLOPT_SSH_AUTH_TYPES = 151
  CURLOPT_FTP_SSL_CCC = 154
  CURLOPT_TIMEOUT_MS = 155
  CURLOPT_CONNECTTIMEOUT_MS = 156
  CURLOPT_HTTP_TRANSFER_DECODING = 157
  CURLOPT_HTTP_CONTENT_DECODING = 158
  CURLOPT_NEW_FILE_PERMS = 159
  CURLOPT_NEW_DIRECTORY_PERMS = 160
  CURLOPT_POSTREDIR = 161
  CURLOPT_PROXY_TRANSFER_MODE = 166
  CURLOPT_ADDRESS_SCOPE = 171
  CURLOPT_CERTINFO = 172
  CURLOPT_TFTP_BLKSIZE = 178
  CURLOPT_SOCKS5_GSSAPI_NEC = 180
  CURLOPT_PROTOCOLS = 181
  CURLOPT_REDIR_PROTOCOLS = 182
  CURLOPT_FTP_USE_PRET = 188
  CURLOPT_RTSP_REQUEST = 189
  CURLOPT_RTSP_CLIENT_CSEQ = 193
  CURLOPT_RTSP_SERVER_CSEQ = 194
  CURLOPT_WILDCARDMATCH = 197
  CURLOPT_TRANSFER_ENCODING = 207
  CURLOPT_GSSAPI_DELEGATION = 210
  CURLOPT_ACCEPTTIMEOUT_MS = 212
  CURLOPT_TCP_KEEPALIVE = 213
  CURLOPT_TCP_KEEPIDLE = 214
  CURLOPT_TCP_KEEPINTVL = 215
  CURLOPT_SSL_OPTIONS = 216
  CURLOPT_SASL_IR = 218
  CURLOPT_SSL_ENABLE_NPN = 225
  CURLOPT_SSL_ENABLE_ALPN = 226
  CURLOPT_EXPECT_100_TIMEOUT_MS = 227
  CURLOPT_HEADEROPT = 229
  CURLOPT_SSL_VERIFYSTATUS = 232
  CURLOPT_SSL_FALSESTART = 233
  CURLOPT_PATH_AS_IS = 234
  CURLOPT_PIPEWAIT = 237
  CURLOPT_STREAM_WEIGHT = 239
  CURLOPT_TFTP_NO_OPTIONS = 242
  CURLOPT_TCP_FASTOPEN = 244
  CURLOPT_KEEP_SENDING_ON_ERROR = 245
  CURLOPT_PROXY_SSL_VERIFYPEER = 248
  CURLOPT_PROXY_SSL_VERIFYHOST = 249
  CURLOPT_PROXY_SSLVERSION = 250
  CURLOPT_PROXY_SSL_OPTIONS = 261
  CURLOPT_SUPPRESS_CONNECT_HEADERS = 265
  CURLOPT_SOCKS5_AUTH = 267
  CURLOPT_SSH_COMPRESSION = 268
  CURLOPT_HAPPY_EYEBALLS_TIMEOUT_MS = 271
  CURLOPT_HAPROXYPROTOCOL = 274
  CURLOPT_DNS_SHUFFLE_ADDRESSES = 275
  CURLOPT_DISALLOW_USERNAME_IN_URL = 278
  CURLOPT_UPLOAD_BUFFERSIZE = 280
  CURLOPT_UPKEEP_INTERVAL_MS = 281
  CURLOPT_HTTP09_ALLOWED = 285
  CURLOPT_ALTSVC_CTRL = 286
  CURLOPT_MAXAGE_CONN = 288
  CURLOPT_MAIL_RCPT_ALLOWFAILS = 290
  CURLOPT_HSTS_CTRL = 299
  CURLOPT_DOH_SSL_VERIFYPEER = 306
  CURLOPT_DOH_SSL_VERIFYHOST = 307
  CURLOPT_DOH_SSL_VERIFYSTATUS = 308
  CURLOPT_MAXLIFETIME_CONN = 314
  CURLOPT_MIME_OPTIONS = 315
  CURLOPT_WS_OPTIONS = 320
  CURLOPT_CA_CACHE_TIMEOUT = 321
  CURLOPT_QUICK_EXIT = 322
  CURLOPT_SERVER_RESPONSE_TIMEOUT_MS = 324
  CURLOPT_TCP_KEEPCNT = 326
  CURLOPT_LASTENTRY = 327
  CURLOPT_WRITEDATA = 10001
  CURLOPT_URL = 10002
  CURLOPT_PROXY = 10004
  CURLOPT_USERPWD = 10005
  CURLOPT_PROXYUSERPWD = 10006
  CURLOPT_RANGE = 10007
  CURLOPT_READDATA = 10009
  CURLOPT_ERRORBUFFER = 10010
  CURLOPT_POSTFIELDS = 10015
  CURLOPT_REFERER = 10016
  CURLOPT_FTPPORT = 10017
  CURLOPT_USERAGENT = 10018
  CURLOPT_COOKIE = 10022
  CURLOPT_HTTPHEADER = 10023
  CURLOPT_HTTPPOST = 10024
  CURLOPT_SSLCERT = 10025
  CURLOPT_KEYPASSWD = 10026
  CURLOPT_QUOTE = 10028
  CURLOPT_HEADERDATA = 10029
  CURLOPT_COOKIEFILE = 10031
  CURLOPT_CUSTOMREQUEST = 10036
  CURLOPT_STDERR = 10037
  CURLOPT_POSTQUOTE = 10039
  CURLOPT_OBSOLETE40 = 10040
  CURLOPT_XFERINFODATA = 10057
  CURLOPT_INTERFACE = 10062
  CURLOPT_KRBLEVEL = 10063
  CURLOPT_CAINFO = 10065
  CURLOPT_TELNETOPTIONS = 10070
  CURLOPT_RANDOM_FILE = 10076
  CURLOPT_EGDSOCKET = 10077
  CURLOPT_COOKIEJAR = 10082
  CURLOPT_SSL_CIPHER_LIST = 10083
  CURLOPT_SSLCERTTYPE = 10086
  CURLOPT_SSLKEY = 10087
  CURLOPT_SSLKEYTYPE = 10088
  CURLOPT_SSLENGINE = 10089
  CURLOPT_PREQUOTE = 10093
  CURLOPT_DEBUGDATA = 10095
  CURLOPT_CAPATH = 10097
  CURLOPT_SHARE = 10100
  CURLOPT_ACCEPT_ENCODING = 10102
  CURLOPT_PRIVATE = 10103
  CURLOPT_HTTP200ALIASES = 10104
  CURLOPT_SSL_CTX_DATA = 10109
  CURLOPT_NETRC_FILE = 10118
  CURLOPT_IOCTLDATA = 10131
  CURLOPT_FTP_ACCOUNT = 10134
  CURLOPT_COOKIELIST = 10135
  CURLOPT_FTP_ALTERNATIVE_TO_USER = 10147
  CURLOPT_SOCKOPTDATA = 10149
  CURLOPT_SSH_PUBLIC_KEYFILE = 10152
  CURLOPT_SSH_PRIVATE_KEYFILE = 10153
  CURLOPT_SSH_HOST_PUBLIC_KEY_MD5 = 10162
  CURLOPT_OPENSOCKETDATA = 10164
  CURLOPT_COPYPOSTFIELDS = 10165
  CURLOPT_SEEKDATA = 10168
  CURLOPT_CRLFILE = 10169
  CURLOPT_ISSUERCERT = 10170
  CURLOPT_USERNAME = 10173
  CURLOPT_PASSWORD = 10174
  CURLOPT_PROXYUSERNAME = 10175
  CURLOPT_PROXYPASSWORD = 10176
  CURLOPT_NOPROXY = 10177
  CURLOPT_SOCKS5_GSSAPI_SERVICE = 10179
  CURLOPT_SSH_KNOWNHOSTS = 10183
  CURLOPT_SSH_KEYDATA = 10185
  CURLOPT_MAIL_FROM = 10186
  CURLOPT_MAIL_RCPT = 10187
  CURLOPT_RTSP_SESSION_ID = 10190
  CURLOPT_RTSP_STREAM_URI = 10191
  CURLOPT_RTSP_TRANSPORT = 10192
  CURLOPT_INTERLEAVEDATA = 10195
  CURLOPT_CHUNK_DATA = 10201
  CURLOPT_FNMATCH_DATA = 10202
  CURLOPT_RESOLVE = 10203
  CURLOPT_TLSAUTH_USERNAME = 10204
  CURLOPT_TLSAUTH_PASSWORD = 10205
  CURLOPT_TLSAUTH_TYPE = 10206
  CURLOPT_CLOSESOCKETDATA = 10209
  CURLOPT_DNS_SERVERS = 10211
  CURLOPT_MAIL_AUTH = 10217
  CURLOPT_XOAUTH2_BEARER = 10220
  CURLOPT_DNS_INTERFACE = 10221
  CURLOPT_DNS_LOCAL_IP4 = 10222
  CURLOPT_DNS_LOCAL_IP6 = 10223
  CURLOPT_LOGIN_OPTIONS = 10224
  CURLOPT_PROXYHEADER = 10228
  CURLOPT_PINNEDPUBLICKEY = 10230
  CURLOPT_UNIX_SOCKET_PATH = 10231
  CURLOPT_PROXY_SERVICE_NAME = 10235
  CURLOPT_SERVICE_NAME = 10236
  CURLOPT_DEFAULT_PROTOCOL = 10238
  CURLOPT_STREAM_DEPENDS = 10240
  CURLOPT_STREAM_DEPENDS_E = 10241
  CURLOPT_CONNECT_TO = 10243
  CURLOPT_PROXY_CAINFO = 10246
  CURLOPT_PROXY_CAPATH = 10247
  CURLOPT_PROXY_TLSAUTH_USERNAME = 10251
  CURLOPT_PROXY_TLSAUTH_PASSWORD = 10252
  CURLOPT_PROXY_TLSAUTH_TYPE = 10253
  CURLOPT_PROXY_SSLCERT = 10254
  CURLOPT_PROXY_SSLCERTTYPE = 10255
  CURLOPT_PROXY_SSLKEY = 10256
  CURLOPT_PROXY_SSLKEYTYPE = 10257
  CURLOPT_PROXY_KEYPASSWD = 10258
  CURLOPT_PROXY_SSL_CIPHER_LIST = 10259
  CURLOPT_PROXY_CRLFILE = 10260
  CURLOPT_PRE_PROXY = 10262
  CURLOPT_PROXY_PINNEDPUBLICKEY = 10263
  CURLOPT_ABSTRACT_UNIX_SOCKET = 10264
  CURLOPT_REQUEST_TARGET = 10266
  CURLOPT_MIMEPOST = 10269
  CURLOPT_RESOLVER_START_DATA = 10273
  CURLOPT_TLS13_CIPHERS = 10276
  CURLOPT_PROXY_TLS13_CIPHERS = 10277
  CURLOPT_DOH_URL = 10279
  CURLOPT_CURLU = 10282
  CURLOPT_TRAILERDATA = 10284
  CURLOPT_ALTSVC = 10287
  CURLOPT_SASL_AUTHZID = 10289
  CURLOPT_PROXY_ISSUERCERT = 10296
  CURLOPT_SSL_EC_CURVES = 10298
  CURLOPT_HSTS = 10300
  CURLOPT_HSTSREADDATA = 10302
  CURLOPT_HSTSWRITEDATA = 10304
  CURLOPT_AWS_SIGV4 = 10305
  CURLOPT_SSH_HOST_PUBLIC_KEY_SHA256 = 10311
  CURLOPT_PREREQDATA = 10313
  CURLOPT_SSH_HOSTKEYDATA = 10317
  CURLOPT_PROTOCOLS_STR = 10318
  CURLOPT_REDIR_PROTOCOLS_STR = 10319
  CURLOPT_HAPROXY_CLIENT_IP = 10323
  CURLOPT_ECH = 10325
  CURLOPT_WRITEFUNCTION = 20011
  CURLOPT_READFUNCTION = 20012
  CURLOPT_PROGRESSFUNCTION = 20056
  CURLOPT_HEADERFUNCTION = 20079
  CURLOPT_DEBUGFUNCTION = 20094
  CURLOPT_SSL_CTX_FUNCTION = 20108
  CURLOPT_IOCTLFUNCTION = 20130
  CURLOPT_CONV_FROM_NETWORK_FUNCTION = 20142
  CURLOPT_CONV_TO_NETWORK_FUNCTION = 20143
  CURLOPT_CONV_FROM_UTF8_FUNCTION = 20144
  CURLOPT_SOCKOPTFUNCTION = 20148
  CURLOPT_OPENSOCKETFUNCTION = 20163
  CURLOPT_SEEKFUNCTION = 20167
  CURLOPT_SSH_KEYFUNCTION = 20184
  CURLOPT_INTERLEAVEFUNCTION = 20196
  CURLOPT_CHUNK_BGN_FUNCTION = 20198
  CURLOPT_CHUNK_END_FUNCTION = 20199
  CURLOPT_FNMATCH_FUNCTION = 20200
  CURLOPT_CLOSESOCKETFUNCTION = 20208
  CURLOPT_XFERINFOFUNCTION = 20219
  CURLOPT_RESOLVER_START_FUNCTION = 20272
  CURLOPT_TRAILERFUNCTION = 20283
  CURLOPT_HSTSREADFUNCTION = 20301
  CURLOPT_HSTSWRITEFUNCTION = 20303
  CURLOPT_PREREQFUNCTION = 20312
  CURLOPT_SSH_HOSTKEYFUNCTION = 20316
  CURLOPT_INFILESIZE_LARGE = 30115
  CURLOPT_RESUME_FROM_LARGE = 30116
  CURLOPT_MAXFILESIZE_LARGE = 30117
  CURLOPT_POSTFIELDSIZE_LARGE = 30120
  CURLOPT_MAX_SEND_SPEED_LARGE = 30145
  CURLOPT_MAX_RECV_SPEED_LARGE = 30146
  CURLOPT_TIMEVALUE_LARGE = 30270
  CURLOPT_SSLCERT_BLOB = 40291
  CURLOPT_SSLKEY_BLOB = 40292
  CURLOPT_PROXY_SSLCERT_BLOB = 40293
  CURLOPT_PROXY_SSLKEY_BLOB = 40294
  CURLOPT_ISSUERCERT_BLOB = 40295
  CURLOPT_PROXY_ISSUERCERT_BLOB = 40297
  CURLOPT_CAINFO_BLOB = 40309
  CURLOPT_PROXY_CAINFO_BLOB = 40310

type
  compiler_builtin_rotateleft32* = object
  struct_IO_wide_data* = object
  XXH_INLINE_private* = object
  compiler_uint128_t* = object
  union_23646* = object
  compiler_int128_t* = object
  restrict* = object
  struct_IO_codecvt* = object
  compiler_builtin_rotateleft64* = object
  extern* = object
  struct_backtrace_state* = object
  compiler_builtin_va_list* = object
  struct_IO_marker* = object

type
  pid_t* = compiler_pid_t ## From /usr/include/sys/types.h:97:17
  struct_termios* {.pure, inheritable, bycopy.} = object
    c_iflag*: tcflag_t ## From /usr/include/bits/termios-struct.h:24:8
    c_oflag*: tcflag_t
    c_cflag*: tcflag_t
    c_lflag*: tcflag_t
    c_line*: cc_t
    c_cc*: array[32, cc_t]
    c_ispeed*: speed_t
    c_ospeed*: speed_t

  struct_winsize* {.pure, inheritable, bycopy.} = object
    ws_row*: cushort ## From /usr/include/bits/ioctl-types.h:27:8
    ws_col*: cushort
    ws_xpixel*: cushort
    ws_ypixel*: cushort

  cp_category_t* = enum_cp_category_t ## From libcon4m/include/vendor/utf8proc.h:36:3
  lbreak_kind_t* = enum_lbreak_kind_t ## From libcon4m/include/vendor/utf8proc.h:42:3
  utf8proc_option_t* = enum_utf8proc_option_t
    ## From libcon4m/include/vendor/utf8proc.h:126:3
  ssize_t* = compiler_ssize_t ## From /usr/include/sys/types.h:108:19
  backtrace_error_callback* = proc(a0: pointer, a1: cstring, a2: cint): void {.cdecl.}
    ## From libcon4m/include/vendor/backtrace.h:66:16
  backtrace_full_callback* =
    proc(a0: pointer, a1: uintptr_t, a2: cstring, a3: cint, a4: cstring): cint {.cdecl.}
    ## From libcon4m/include/vendor/backtrace.h:101:15
  uintptr_t* = culong ## From /usr/include/stdint.h:79:27
  backtrace_simple_callback* = proc(a0: pointer, a1: uintptr_t): cint {.cdecl.}
    ## From libcon4m/include/vendor/backtrace.h:119:15
  FILE* = struct_IO_FILE ## From /usr/include/bits/types/FILE.h:7:25
  backtrace_syminfo_callback* = proc(
    a0: pointer, a1: uintptr_t, a2: cstring, a3: uintptr_t, a4: uintptr_t
  ): void {.cdecl.} ## From libcon4m/include/vendor/backtrace.h:155:16
  mmm_cleanup_func* = proc(a0: pointer, a1: pointer): void {.cdecl.}
    ## From libcon4m/include/hatrack/mmm.h:34:16
  mmm_header_t* = struct_mmm_header_st ## From libcon4m/include/hatrack/mmm.h:47:30
  struct_mmm_header_st* {.pure, inheritable, bycopy.} = object
    next*: ptr mmm_header_t ## From libcon4m/include/hatrack/mmm.h:48:8
    create_epoch*: Atomic[uint64]
    write_epoch*: Atomic[uint64]
    retire_epoch*: uint64
    cleanup*: mmm_cleanup_func
    cleanup_aux*: pointer
    size*: csize_t
    padding*: uint64
    data*: ptr UncheckedArray[uint8]

  mmm_thread_t* = struct_mmm_thread_st ## From libcon4m/include/hatrack/mmm.h:87:30
  struct_mmm_thread_st* {.pure, inheritable, bycopy.} = object
    tid*: int64 ## From libcon4m/include/hatrack/mmm.h:88:8
    retire_ctr*: int64
    retire_list*: ptr mmm_header_t
    initialized*: bool

  mmm_thread_acquire_func* = proc(a0: pointer, a1: csize_t): ptr mmm_thread_t {.cdecl.}
    ## From libcon4m/include/hatrack/mmm.h:118:25
  mmm_enum_t* = enum_mmm_enum_t ## From libcon4m/include/hatrack/mmm.h:343:1
  hatrack_hash_t* = compiler_int128_t
    ## From libcon4m/include/hatrack/hatrack_common.h:39:20
  hatrack_hash_func_t* = proc(a0: pointer): hatrack_hash_t {.cdecl.}
    ## From libcon4m/include/hatrack/hatrack_common.h:93:26
  hatrack_mem_hook_t* = proc(a0: pointer, a1: pointer): void {.cdecl.}
    ## From libcon4m/include/hatrack/hatrack_common.h:126:16
  struct_hatrack_view_t* {.pure, inheritable, bycopy.} = object
    item*: pointer ## From libcon4m/include/hatrack/hatrack_common.h:154:9
    sort_epoch*: int64

  hatrack_view_t* = struct_hatrack_view_t
    ## From libcon4m/include/hatrack/hatrack_common.h:157:3
  hatrack_panic_func* = proc(a0: pointer, a1: cstring): void {.cdecl.}
    ## From libcon4m/include/hatrack/hatrack_common.h:177:16
  hatrack_init_func* = proc(a0: pointer): void {.cdecl.}
    ## From libcon4m/include/hatrack/hatrack_common.h:221:27
  hatrack_init_sz_func* = proc(a0: pointer, a1: cschar): void {.cdecl.}
    ## From libcon4m/include/hatrack/hatrack_common.h:222:27
  hatrack_get_func* = proc(
    a0: pointer, a1: ptr mmm_thread_t, a2: hatrack_hash_t, a3: ptr bool
  ): pointer {.cdecl.} ## From libcon4m/include/hatrack/hatrack_common.h:223:27
  hatrack_put_func* = proc(
    a0: pointer, a1: ptr mmm_thread_t, a2: hatrack_hash_t, a3: pointer, a4: ptr bool
  ): pointer {.cdecl.} ## From libcon4m/include/hatrack/hatrack_common.h:224:27
  hatrack_replace_func* = proc(
    a0: pointer, a1: ptr mmm_thread_t, a2: hatrack_hash_t, a3: pointer, a4: ptr bool
  ): pointer {.cdecl.} ## From libcon4m/include/hatrack/hatrack_common.h:225:27
  hatrack_add_func* = proc(
    a0: pointer, a1: ptr mmm_thread_t, a2: hatrack_hash_t, a3: pointer
  ): bool {.cdecl.} ## From libcon4m/include/hatrack/hatrack_common.h:226:27
  hatrack_remove_func* = proc(
    a0: pointer, a1: ptr mmm_thread_t, a2: hatrack_hash_t, a3: ptr bool
  ): pointer {.cdecl.} ## From libcon4m/include/hatrack/hatrack_common.h:227:27
  hatrack_delete_func* = proc(a0: pointer): void {.cdecl.}
    ## From libcon4m/include/hatrack/hatrack_common.h:228:27
  hatrack_len_func* = proc(a0: pointer, a1: ptr mmm_thread_t): uint64 {.cdecl.}
    ## From libcon4m/include/hatrack/hatrack_common.h:229:27
  hatrack_view_func* = proc(
    a0: pointer, a1: ptr mmm_thread_t, a2: ptr uint64, a3: bool
  ): ptr hatrack_view_t {.cdecl.}
    ## From libcon4m/include/hatrack/hatrack_common.h:230:27
  struct_hatrack_vtable_st* {.pure, inheritable, bycopy.} = object
    init*: hatrack_init_func ## From libcon4m/include/hatrack/hatrack_common.h:232:16
    init_sz*: hatrack_init_sz_func
    get*: hatrack_get_func
    put*: hatrack_put_func
    replace*: hatrack_replace_func
    add*: hatrack_add_func
    remove*: hatrack_remove_func
    delete*: hatrack_delete_func
    len*: hatrack_len_func
    view*: hatrack_view_func

  hatrack_vtable_t* = struct_hatrack_vtable_st
    ## From libcon4m/include/hatrack/hatrack_common.h:243:3
  struct_crown_record_t* {.pure, inheritable, bycopy.} = object
    item*: pointer ## From libcon4m/include/hatrack/crown.h:33:9
    info*: uint64

  crown_record_t* = struct_crown_record_t ## From libcon4m/include/hatrack/crown.h:36:3
  struct_crown_bucket_t* {.pure, inheritable, bycopy.} = object
    hv*: Atomic[hatrack_hash_t] ## From libcon4m/include/hatrack/crown.h:38:9
    record*: Atomic[crown_record_t]
    neighbor_map*: Atomic[uint64]

  crown_bucket_t* = struct_crown_bucket_t ## From libcon4m/include/hatrack/crown.h:47:3
  crown_store_t* = struct_crown_store_st ## From libcon4m/include/hatrack/crown.h:49:31
  struct_crown_store_st* {.pure, inheritable, bycopy.} = object
    store_next*: Atomic[ptr crown_store_t] ## From libcon4m/include/hatrack/crown.h:51:8
    last_slot*: uint64
    threshold*: uint64
    used_count*: Atomic[uint64]
    claimed*: Atomic[bool]
    buckets*: ptr UncheckedArray[crown_bucket_t]

  struct_crown_t* {.pure, inheritable, bycopy.} = object
    store_current*: Atomic[ptr crown_store_t]
      ## From libcon4m/include/hatrack/crown.h:60:9
    item_count*: Atomic[uint64]
    help_needed*: Atomic[uint64]
    next_epoch*: uint64

  crown_t* = struct_crown_t ## From libcon4m/include/hatrack/crown.h:68:3
  woolhat_record_t* = struct_woolhat_record_st
    ## From libcon4m/include/hatrack/woolhat.h:30:34
  struct_woolhat_record_st* {.pure, inheritable, bycopy.} = object
    next*: ptr woolhat_record_t ## From libcon4m/include/hatrack/woolhat.h:32:8
    item*: pointer
    deleted*: bool

  struct_woolhat_state_t* {.pure, inheritable, bycopy.} = object
    head*: ptr woolhat_record_t ## From libcon4m/include/hatrack/woolhat.h:38:9
    flags*: uint64

  woolhat_state_t* = struct_woolhat_state_t
    ## From libcon4m/include/hatrack/woolhat.h:41:3
  struct_woolhat_history_t* {.pure, inheritable, bycopy.} = object
    hv*: Atomic[hatrack_hash_t] ## From libcon4m/include/hatrack/woolhat.h:43:9
    state*: Atomic[woolhat_state_t]

  woolhat_history_t* = struct_woolhat_history_t
    ## From libcon4m/include/hatrack/woolhat.h:46:3
  woolhat_store_t* = struct_woolhat_store_st
    ## From libcon4m/include/hatrack/woolhat.h:48:33
  struct_woolhat_store_st* {.pure, inheritable, bycopy.} = object
    last_slot*: uint64 ## From libcon4m/include/hatrack/woolhat.h:50:8
    threshold*: uint64
    used_count*: Atomic[uint64]
    store_next*: Atomic[ptr woolhat_store_t]
    hist_buckets*: ptr UncheckedArray[woolhat_history_t]

  struct_woolhat_st* {.pure, inheritable, bycopy.} = object
    store_current*: Atomic[ptr woolhat_store_t]
      ## From libcon4m/include/hatrack/woolhat.h:58:16
    item_count*: Atomic[uint64]
    help_needed*: Atomic[uint64]
    cleanup_func*: mmm_cleanup_func
    cleanup_aux*: pointer

  woolhat_t* = struct_woolhat_st ## From libcon4m/include/hatrack/woolhat.h:64:3
  struct_hatrack_set_view_t* {.pure, inheritable, bycopy.} = object
    hv*: hatrack_hash_t ## From libcon4m/include/hatrack/woolhat.h:71:9
    item*: pointer
    sort_epoch*: int64

  hatrack_set_view_t* = struct_hatrack_set_view_t
    ## From libcon4m/include/hatrack/woolhat.h:75:3
  struct_refhat_bucket_t* {.pure, inheritable, bycopy.} = object
    hv*: hatrack_hash_t ## From libcon4m/include/hatrack/refhat.h:59:9
    item*: pointer
    epoch*: uint64

  refhat_bucket_t* = struct_refhat_bucket_t
    ## From libcon4m/include/hatrack/refhat.h:63:3
  struct_refhat_t* {.pure, inheritable, bycopy.} = object
    last_slot*: uint64 ## From libcon4m/include/hatrack/refhat.h:100:9
    threshold*: uint64
    used_count*: uint64
    item_count*: uint64
    buckets*: ptr refhat_bucket_t
    buckets_size*: uint64
    next_epoch*: uint64

  refhat_t* = struct_refhat_t ## From libcon4m/include/hatrack/refhat.h:108:3
  struct_hatrack_offset_info_t* {.pure, inheritable, bycopy.} = object
    hash_offset*: int32 ## From libcon4m/include/hatrack/dict.h:44:9
    cache_offset*: int32

  hatrack_offset_info_t* = struct_hatrack_offset_info_t
    ## From libcon4m/include/hatrack/dict.h:47:3
  struct_hatrack_dict_item_t* {.pure, inheritable, bycopy.} = object
    key*: pointer ## From libcon4m/include/hatrack/dict.h:49:9
    value*: pointer

  hatrack_dict_item_t* = struct_hatrack_dict_item_t
    ## From libcon4m/include/hatrack/dict.h:52:3
  hatrack_dict_t* = struct_hatrack_dict_t ## From libcon4m/include/hatrack/dict.h:54:31
  struct_hatrack_dict_t* {.pure, inheritable, bycopy.} = object
    crown_instance*: crown_t ## From libcon4m/include/hatrack/dict.h:64:8
    key_type*: uint32
    slow_views*: bool
    sorted_views*: bool
    hash_info*: hatrack_hash_info_t
    free_handler*: hatrack_mem_hook_t
    key_return_hook*: hatrack_mem_hook_t
    val_return_hook*: hatrack_mem_hook_t

  hatrack_dict_key_t* = pointer ## From libcon4m/include/hatrack/dict.h:56:15
  hatrack_dict_value_t* = pointer ## From libcon4m/include/hatrack/dict.h:57:15
  union_hatrack_hash_info_t* {.union, bycopy.} = object
    offsets*: hatrack_offset_info_t ## From libcon4m/include/hatrack/dict.h:59:9
    custom_hash*: hatrack_hash_func_t

  hatrack_hash_info_t* = union_hatrack_hash_info_t
    ## From libcon4m/include/hatrack/dict.h:62:3
  hatrack_set_t* = struct_hatrack_set_st ## From libcon4m/include/hatrack/set.h:30:31
  struct_hatrack_set_st* {.pure, inheritable, bycopy.} = object
    woolhat_instance*: woolhat_t ## From libcon4m/include/hatrack/set.h:32:8
    item_type*: uint32
    hash_info*: hatrack_hash_info_t
    pre_return_hook*: hatrack_mem_hook_t
    free_handler*: hatrack_mem_hook_t

  flex_callback_t* = proc(a0: pointer): void {.cdecl.}
    ## From libcon4m/include/hatrack/flexarray.h:31:16
  struct_flex_item_t* {.pure, inheritable, bycopy.} = object
    item*: pointer ## From libcon4m/include/hatrack/flexarray.h:33:9
    state*: uint64

  flex_item_t* = struct_flex_item_t ## From libcon4m/include/hatrack/flexarray.h:36:3
  flex_cell_t* = Atomic[flex_item_t] ## From libcon4m/include/hatrack/flexarray.h:38:29
  flex_store_t* = struct_flex_store_t ## From libcon4m/include/hatrack/flexarray.h:40:29
  struct_flex_store_t* {.pure, inheritable, bycopy.} = object
    store_size*: uint64 ## From libcon4m/include/hatrack/flexarray.h:48:8
    array_size*: Atomic[uint64]
    next*: Atomic[ptr flex_store_t]
    claimed*: Atomic[bool]
    cells*: ptr UncheckedArray[flex_cell_t]

  struct_flex_view_t* {.pure, inheritable, bycopy.} = object
    next_ix*: uint64 ## From libcon4m/include/hatrack/flexarray.h:42:9
    contents*: ptr flex_store_t
    eject_callback*: flex_callback_t

  flex_view_t* = struct_flex_view_t ## From libcon4m/include/hatrack/flexarray.h:46:3
  struct_flexarray_t* {.pure, inheritable, bycopy.} = object
    ret_callback*: flex_callback_t ## From libcon4m/include/hatrack/flexarray.h:56:16
    eject_callback*: flex_callback_t
    store*: Atomic[ptr flex_store_t]

  flexarray_t* = struct_flexarray_t ## From libcon4m/include/hatrack/flexarray.h:60:3
  hatrack_malloc_t* = proc(a0: csize_t, a1: pointer): pointer {.cdecl.}
    ## From libcon4m/include/hatrack/malloc.h:34:17
  hatrack_realloc_t* =
    proc(a0: pointer, a1: csize_t, a2: csize_t, a3: pointer): pointer {.cdecl.}
    ## From libcon4m/include/hatrack/malloc.h:55:17
  hatrack_free_t* = proc(a0: pointer, a1: csize_t, a2: pointer): void {.cdecl.}
    ## From libcon4m/include/hatrack/malloc.h:71:16
  struct_hatrack_mem_manager_t* {.pure, inheritable, bycopy.} = object
    mallocfn*: hatrack_malloc_t ## From libcon4m/include/hatrack/malloc.h:74:9
    zallocfn*: hatrack_malloc_t
    reallocfn*: hatrack_realloc_t
    freefn*: hatrack_free_t
    arg*: pointer

  hatrack_mem_manager_t* = struct_hatrack_mem_manager_t
    ## From libcon4m/include/hatrack/malloc.h:80:3
  XXH_NAMESPACEXXH_errorcode* = enum_XXH_NAMESPACEXXH_errorcode
    ## From libcon4m/include/hatrack/xxhash.h:355:3
  XXH32_hash_t* = uint32 ## From libcon4m/include/hatrack/xxhash.h:373:18
  XXH_NAMESPACEXXH32_state_t* = struct_XXH_NAMESPACEXXH32_state_s
    ## From libcon4m/include/hatrack/xxhash.h:490:30
  struct_XXH_NAMESPACEXXH32_state_s* {.pure, inheritable, bycopy.} = object
    total_len_32*: XXH32_hash_t ## From libcon4m/include/hatrack/xxhash.h:1034:8
    large_len*: XXH32_hash_t
    v1*: XXH32_hash_t
    v2*: XXH32_hash_t
    v3*: XXH32_hash_t
    v4*: XXH32_hash_t
    mem32*: array[4, XXH32_hash_t]
    memsize*: XXH32_hash_t
    reserved*: XXH32_hash_t

  struct_XXH_NAMESPACEXXH32_canonical_t* {.pure, inheritable, bycopy.} = object
    digest*: array[4, uint8] ## From libcon4m/include/hatrack/xxhash.h:600:9

  XXH_NAMESPACEXXH32_canonical_t* = struct_XXH_NAMESPACEXXH32_canonical_t
    ## From libcon4m/include/hatrack/xxhash.h:602:3
  XXH64_hash_t* = uint64 ## From libcon4m/include/hatrack/xxhash.h:687:18
  XXH_NAMESPACEXXH64_state_t* = struct_XXH_NAMESPACEXXH64_state_s
    ## From libcon4m/include/hatrack/xxhash.h:747:31
  struct_XXH_NAMESPACEXXH64_state_s* {.pure, inheritable, bycopy.} = object
    total_len*: XXH64_hash_t ## From libcon4m/include/hatrack/xxhash.h:1063:8
    v1*: XXH64_hash_t
    v2*: XXH64_hash_t
    v3*: XXH64_hash_t
    v4*: XXH64_hash_t
    mem64*: array[4, XXH64_hash_t]
    memsize*: XXH32_hash_t
    reserved32*: XXH32_hash_t
    reserved64*: XXH64_hash_t

  struct_XXH_NAMESPACEXXH64_canonical_t* {.pure, inheritable, bycopy.} = object
    digest*: array[8, uint8] ## From libcon4m/include/hatrack/xxhash.h:761:9

  XXH_NAMESPACEXXH64_canonical_t* = struct_XXH_NAMESPACEXXH64_canonical_t
    ## From libcon4m/include/hatrack/xxhash.h:763:3
  XXH_NAMESPACEXXH3_state_t* = struct_XXH_NAMESPACEXXH3_state_s
    ## From libcon4m/include/hatrack/xxhash.h:874:30
  struct_XXH_NAMESPACEXXH3_state_s* {.pure, inheritable, bycopy.} = object
    acc*: array[8, XXH64_hash_t] ## From libcon4m/include/hatrack/xxhash.h:1140:8
    customSecret*: array[192, uint8]
    buffer*: array[256, uint8]
    bufferedSize*: XXH32_hash_t
    reserved32*: XXH32_hash_t
    nbStripesSoFar*: csize_t
    totalLen*: XXH64_hash_t
    nbStripesPerBlock*: csize_t
    secretLimit*: csize_t
    seed*: XXH64_hash_t
    reserved64*: XXH64_hash_t
    extSecret*: ptr uint8

  struct_XXH_NAMESPACEXXH128_hash_t* {.pure, inheritable, bycopy.} = object
    low64*: XXH64_hash_t ## From libcon4m/include/hatrack/xxhash.h:925:9
    high64*: XXH64_hash_t

  XXH_NAMESPACEXXH128_hash_t* = struct_XXH_NAMESPACEXXH128_hash_t
    ## From libcon4m/include/hatrack/xxhash.h:928:3
  struct_XXH_NAMESPACEXXH128_canonical_t* {.pure, inheritable, bycopy.} = object
    digest*: array[16, uint8] ## From libcon4m/include/hatrack/xxhash.h:990:9

  XXH_NAMESPACEXXH128_canonical_t* = struct_XXH_NAMESPACEXXH128_canonical_t
    ## From libcon4m/include/hatrack/xxhash.h:992:3
  xxh_u8* = uint8 ## From libcon4m/include/hatrack/xxhash.h:1640:17
  xxh_u32* = XXH32_hash_t ## From libcon4m/include/hatrack/xxhash.h:1644:22
  XXH_alignment* = enum_XXH_alignment ## From libcon4m/include/hatrack/xxhash.h:1883:3
  xxh_u64* = XXH64_hash_t ## From libcon4m/include/hatrack/xxhash.h:2425:22
  xxh_i64* = int64 ## From libcon4m/include/hatrack/xxhash.h:4155:17
  XXH3_f_accumulate_512* = proc(a0: pointer, a1: pointer, a2: pointer): void {.cdecl.}
    ## From libcon4m/include/hatrack/xxhash.h:4834:16
  XXH3_f_scrambleAcc* = proc(a0: pointer, a1: pointer): void {.cdecl.}
    ## From libcon4m/include/hatrack/xxhash.h:4837:16
  XXH3_f_initCustomSecret* = proc(a0: pointer, a1: xxh_u64): void {.cdecl.}
    ## From libcon4m/include/hatrack/xxhash.h:4838:16
  XXH3_hashLong64_f* = proc(
    a0: pointer, a1: csize_t, a2: XXH64_hash_t, a3: ptr xxh_u8, a4: csize_t
  ): XXH64_hash_t {.cdecl.} ## From libcon4m/include/hatrack/xxhash.h:5138:24
  XXH3_hashLong128_f* = proc(
    a0: pointer, a1: csize_t, a2: XXH64_hash_t, a3: pointer, a4: csize_t
  ): XXH_NAMESPACEXXH128_hash_t {.cdecl.}
    ## From libcon4m/include/hatrack/xxhash.h:6112:25
  union_hash_internal_conversion_t* {.union, bycopy.} = object
    lhv*: hatrack_hash_t ## From libcon4m/include/hatrack/hash.h:38:9
    xhv*: XXH_NAMESPACEXXH128_hash_t

  hash_internal_conversion_t* = union_hash_internal_conversion_t
    ## From libcon4m/include/hatrack/hash.h:41:3
  struct_queue_item_t* {.pure, inheritable, bycopy.} = object
    item*: pointer ## From libcon4m/include/hatrack/queue.h:82:9
    state*: uint64

  queue_item_t* = struct_queue_item_t ## From libcon4m/include/hatrack/queue.h:85:3
  queue_cell_t* = Atomic[queue_item_t] ## From libcon4m/include/hatrack/queue.h:87:30
  queue_segment_t* = struct_queue_segment_st
    ## From libcon4m/include/hatrack/queue.h:89:33
  struct_queue_segment_st* {.pure, inheritable, bycopy.} = object
    next*: Atomic[ptr queue_segment_t] ## From libcon4m/include/hatrack/queue.h:99:8
    size*: uint64
    enqueue_index*: Atomic[uint64]
    dequeue_index*: Atomic[uint64]
    cells*: ptr UncheckedArray[queue_cell_t]

  struct_queue_seg_ptrs_t* {.pure, inheritable, bycopy.} = object
    enqueue_segment*: ptr queue_segment_t ## From libcon4m/include/hatrack/queue.h:107:9
    dequeue_segment*: ptr queue_segment_t

  queue_seg_ptrs_t* = struct_queue_seg_ptrs_t
    ## From libcon4m/include/hatrack/queue.h:111:3
  struct_hatrack_queue_t* {.pure, inheritable, bycopy.} = object
    segments*: Atomic[queue_seg_ptrs_t] ## From libcon4m/include/hatrack/queue.h:113:16
    default_segment_size*: uint64
    help_needed*: Atomic[uint64]
    len*: Atomic[uint64]

  queue_t* = struct_hatrack_queue_t ## From libcon4m/include/hatrack/queue.h:118:3
  struct_stack_item_t* {.pure, inheritable, bycopy.} = object
    item*: pointer ## From libcon4m/include/hatrack/stack.h:47:9
    state*: uint32
    valid_after*: uint32

  stack_item_t* = struct_stack_item_t ## From libcon4m/include/hatrack/stack.h:51:3
  stack_cell_t* = Atomic[stack_item_t] ## From libcon4m/include/hatrack/stack.h:53:30
  stack_store_t* = struct_stack_store_t ## From libcon4m/include/hatrack/stack.h:54:30
  struct_stack_store_t* {.pure, inheritable, bycopy.} = object
    num_cells*: uint64 ## From libcon4m/include/hatrack/stack.h:61:8
    head_state*: Atomic[uint64]
    next_store*: Atomic[ptr stack_store_t]
    claimed*: Atomic[bool]
    cells*: ptr UncheckedArray[stack_cell_t]

  struct_stack_view_t* {.pure, inheritable, bycopy.} = object
    next_ix*: uint64 ## From libcon4m/include/hatrack/stack.h:56:9
    store*: ptr stack_store_t

  stack_view_t* = struct_stack_view_t ## From libcon4m/include/hatrack/stack.h:59:3
  struct_hatstack_t* {.pure, inheritable, bycopy.} = object
    store*: Atomic[ptr stack_store_t] ## From libcon4m/include/hatrack/stack.h:69:9
    compress_threshold*: uint64

  hatstack_t* = struct_hatstack_t ## From libcon4m/include/hatrack/stack.h:75:3
  struct_hatring_item_t* {.pure, inheritable, bycopy.} = object
    item*: pointer ## From libcon4m/include/hatrack/hatring.h:47:9
    state*: uint64

  hatring_item_t* = struct_hatring_item_t ## From libcon4m/include/hatrack/hatring.h:50:3
  hatring_cell_t* = Atomic[hatring_item_t]
    ## From libcon4m/include/hatrack/hatring.h:52:32
  hatring_drop_handler* = proc(a0: pointer): void {.cdecl.}
    ## From libcon4m/include/hatrack/hatring.h:54:16
  struct_hatring_view_t* {.pure, inheritable, bycopy.} = object
    next_ix*: uint64 ## From libcon4m/include/hatrack/hatring.h:56:9
    num_items*: uint64
    cells*: ptr UncheckedArray[pointer]

  hatring_view_t* = struct_hatring_view_t ## From libcon4m/include/hatrack/hatring.h:60:3
  struct_hatring_t* {.pure, inheritable, bycopy.} = object
    epochs*: Atomic[uint64] ## From libcon4m/include/hatrack/hatring.h:62:9
    drop_handler*: hatring_drop_handler
    last_slot*: uint64
    size*: uint64
    cells*: ptr UncheckedArray[hatring_cell_t]

  hatring_t* = struct_hatring_t ## From libcon4m/include/hatrack/hatring.h:68:3
  struct_logring_view_entry_t* {.pure, inheritable, bycopy.} = object
    offset_entry_ix*: Atomic[uint64] ## From libcon4m/include/hatrack/logring.h:159:9
    len*: Atomic[uint64]
    cell_skipped*: Atomic[bool]
    value*: Atomic[pointer]

  logring_view_entry_t* = struct_logring_view_entry_t
    ## From libcon4m/include/hatrack/logring.h:164:3
  struct_logring_view_t* {.pure, inheritable, bycopy.} = object
    start_epoch*: uint64 ## From libcon4m/include/hatrack/logring.h:168:9
    next_ix*: uint64
    num_cells*: Atomic[uint64]
    cells*: ptr UncheckedArray[logring_view_entry_t]

  logring_view_t* = struct_logring_view_t
    ## From libcon4m/include/hatrack/logring.h:173:3
  struct_logring_entry_info_t* {.pure, inheritable, bycopy.} = object
    write_epoch*: uint32 ## From libcon4m/include/hatrack/logring.h:176:9
    state*: uint32
    view_id*: uint64

  logring_entry_info_t* = struct_logring_entry_info_t
    ## From libcon4m/include/hatrack/logring.h:181:3
  struct_logring_entry_t* {.pure, inheritable, bycopy.} = object
    info*: Atomic[logring_entry_info_t] ## From libcon4m/include/hatrack/logring.h:184:9
    len*: uint64
    data*: ptr UncheckedArray[cschar]

  logring_entry_t* = struct_logring_entry_t
    ## From libcon4m/include/hatrack/logring.h:188:3
  struct_view_info_t* {.pure, inheritable, bycopy.} = object
    view*: ptr logring_view_t ## From libcon4m/include/hatrack/logring.h:190:9
    last_viewid*: uint64

  view_info_t* = struct_view_info_t ## From libcon4m/include/hatrack/logring.h:193:3
  struct_logring_t* {.pure, inheritable, bycopy.} = object
    entry_ix*: Atomic[uint64] ## From libcon4m/include/hatrack/logring.h:195:9
    last_entry*: uint64
    entry_len*: uint64
    view_state*: Atomic[view_info_t]
    ring*: ptr hatring_t
    entries_size*: uint64
    entries*: ptr logring_entry_t

  logring_t* = struct_logring_t ## From libcon4m/include/hatrack/logring.h:203:3
  struct_hatrack_zarray_t* {.pure, inheritable, bycopy.} = object
    length*: Atomic[uint32] ## From libcon4m/include/hatrack/zeroarray.h:81:9
    last_item*: uint32
    cell_size*: uint32
    alloc_len*: uint32
    data*: ptr UncheckedArray[cschar]

  hatrack_zarray_t* = struct_hatrack_zarray_t
    ## From libcon4m/include/hatrack/zeroarray.h:87:3
  c4m_dict_t* = struct_hatrack_dict_t ## From libcon4m/include/con4m/base.h:73:31
  c4m_set_t* = struct_hatrack_set_st ## From libcon4m/include/con4m/datatypes.h:3:31
  union_c4m_box_t* {.union, bycopy.} = object
    b*: bool ## From libcon4m/include/adts/dt_box.h:4:9
    i8*: int8
    u8*: uint8
    i16*: int16
    u16*: uint16
    i32*: int32
    u32*: uint32
    i64*: int64
    u64*: uint64
    dbl*: cdouble
    v*: pointer

  c4m_box_t* = union_c4m_box_t ## From libcon4m/include/adts/dt_box.h:16:3
  c4m_mem_scan_fn* = proc(a0: ptr uint64, a1: pointer): void {.cdecl.}
    ## From libcon4m/include/core/dt_alloc.h:4:16
  struct_c4m_alloc_hdr* {.pure, inheritable, bycopy.} = object
    guard*: uint64 ## From libcon4m/include/core/dt_alloc.h:6:16
    next_addr*: ptr uint64
    fw_addr*: ptr struct_c4m_alloc_hdr
    arena*: ptr struct_c4m_arena_t
    alloc_len*: uint32
    request_len*: uint32
    scan_fn*: c4m_mem_scan_fn
    finalize* {.bitsize: 1.}: cuint
    con4m_obj* {.bitsize: 1.}: cuint
    cached_hash*: compiler_uint128_t
    data*: ptr UncheckedArray[uint64]

  struct_c4m_arena_t* {.pure, inheritable, bycopy.} = object
    next_alloc*: ptr c4m_alloc_hdr ## From libcon4m/include/core/dt_alloc.h:106:16
    roots*: ptr hatrack_zarray_t
    external_holds*: ptr c4m_set_t
    heap_end*: ptr uint64
    to_finalize*: ptr c4m_finalizer_info_t
    alloc_count*: uint32
    largest_alloc*: uint32
    grow_next*: bool
    data*: ptr UncheckedArray[uint64]

  c4m_alloc_hdr* = struct_c4m_alloc_hdr ## From libcon4m/include/core/dt_alloc.h:77:3
  struct_c4m_finalizer_info_t* {.pure, inheritable, bycopy.} = object
    allocation*: ptr c4m_alloc_hdr ## From libcon4m/include/core/dt_alloc.h:79:16
    next*: ptr struct_c4m_finalizer_info_t
    prev*: ptr struct_c4m_finalizer_info_t

  c4m_finalizer_info_t* = struct_c4m_finalizer_info_t
    ## From libcon4m/include/core/dt_alloc.h:83:3
  struct_c4m_gc_root_info_t* {.pure, inheritable, bycopy.} = object
    ptr_field*: pointer ## From libcon4m/include/core/dt_alloc.h:97:9
    num_items*: uint64

  c4m_gc_root_info_t* = struct_c4m_gc_root_info_t
    ## From libcon4m/include/core/dt_alloc.h:104:3
  c4m_arena_t* = struct_c4m_arena_t ## From libcon4m/include/core/dt_alloc.h:128:3
  c4m_system_finalizer_fn* = proc(a0: pointer): void {.cdecl.}
    ## From libcon4m/include/core/dt_alloc.h:130:16
  struct_c4m_one_karg_t* {.pure, inheritable, bycopy.} = object
    kw*: cstring ## From libcon4m/include/core/dt_kargs.h:5:9
    value*: pointer

  c4m_one_karg_t* = struct_c4m_one_karg_t ## From libcon4m/include/core/dt_kargs.h:8:3
  struct_c4m_karg_info_t* {.pure, inheritable, bycopy.} = object
    num_provided*: int64 ## From libcon4m/include/core/dt_kargs.h:10:9
    args*: ptr c4m_one_karg_t

  c4m_karg_info_t* = struct_c4m_karg_info_t ## From libcon4m/include/core/dt_kargs.h:13:3
  c4m_base_obj_t* = struct_c4m_base_obj_t ## From libcon4m/include/core/dt_objects.h:4:31
  struct_c4m_base_obj_t* {.pure, inheritable, bycopy.} = object
    base_data_type*: ptr c4m_dt_info_t ## From libcon4m/include/core/dt_objects.h:64:8
    concrete_type*: ptr struct_c4m_type_t
    data*: ptr UncheckedArray[uint64]

  c4m_obj_t* = pointer ## From libcon4m/include/core/dt_objects.h:5:31
  c4m_dt_kind_t* = enum_c4m_dt_kind_t ## From libcon4m/include/core/dt_objects.h:20:3
  c4m_vtable_entry* = proc(a0: ptr c4m_obj_t): void {.cdecl, varargs.}
    ## From libcon4m/include/core/dt_objects.h:24:16
  c4m_container_init* = proc(a0: ptr c4m_obj_t, a1: pointer): void {.cdecl, varargs.}
    ## From libcon4m/include/core/dt_objects.h:25:16
  struct_c4m_vtable_t* {.pure, inheritable, bycopy.} = object
    num_entries*: uint64 ## From libcon4m/include/core/dt_objects.h:27:9
    methods*: ptr UncheckedArray[c4m_vtable_entry]

  c4m_vtable_t* = struct_c4m_vtable_t ## From libcon4m/include/core/dt_objects.h:30:3
  struct_c4m_dt_info_t* {.pure, inheritable, bycopy.} = object
    name*: cstring ## From libcon4m/include/core/dt_objects.h:32:9
    typeid*: uint64
    vtable*: ptr c4m_vtable_t
    hash_fn*: uint32
    alloc_len*: uint32
    dt_kind*: c4m_dt_kind_t
    by_value* {.bitsize: 1.}: bool

  c4m_dt_info_t* = struct_c4m_dt_info_t ## From libcon4m/include/core/dt_objects.h:48:3
  struct_c4m_type_t* {.pure, inheritable, bycopy.} = object
    details*: ptr c4m_type_info_t ## From libcon4m/include/core/dt_types.h:15:16
    fw*: c4m_type_hash_t
    typeid*: c4m_type_hash_t

  c4m_builtin_type_fn* = enum_c4m_builtin_type_fn
    ## From libcon4m/include/core/dt_objects.h:128:3
  c4m_ix_item_sz_t* = enum_c4m_ix_item_sz_t
    ## From libcon4m/include/core/dt_objects.h:136:3
  c4m_builtin_t* = enum_c4m_builtin_t ## From libcon4m/include/core/dt_objects.h:191:3
  c4m_lit_syntax_t* = enum_c4m_lit_syntax_t
    ## From libcon4m/include/core/dt_literals.h:15:3
  struct_c4m_lit_info_t* {.pure, inheritable, bycopy.} = object
    litmod*: ptr struct_c4m_str_t ## From libcon4m/include/core/dt_literals.h:17:9
    cast_to*: ptr struct_c4m_type_t
    type_field*: ptr struct_c4m_type_t
    base_type*: c4m_builtin_t
    st*: c4m_lit_syntax_t
    num_items*: cint

  struct_c4m_str_t* {.pure, inheritable, bycopy.} = object
    data*: cstring ## From libcon4m/include/adts/dt_strings.h:14:16
    styling*: ptr c4m_style_info_t
    byte_len*: int32
    codepoints*: int32
    utf32* {.bitsize: 1.}: cuint

  c4m_lit_info_t* = struct_c4m_lit_info_t
    ## From libcon4m/include/core/dt_literals.h:24:3
  c4m_color_t* = int32 ## From libcon4m/include/util/dt_colors.h:5:17
  struct_c4m_color_info_t* {.pure, inheritable, bycopy.} = object
    name*: cstring ## From libcon4m/include/util/dt_colors.h:7:9
    rgb*: int32

  c4m_color_info_t* = struct_c4m_color_info_t
    ## From libcon4m/include/util/dt_colors.h:10:3
  c4m_codepoint_t* = int32 ## From libcon4m/include/adts/dt_codepoints.h:5:17
  c4m_style_t* = uint64 ## From libcon4m/include/util/dt_styles.h:4:18
  struct_c4m_style_entry_t* {.pure, inheritable, bycopy.} = object
    start*: int32 ## From libcon4m/include/util/dt_styles.h:6:9
    end_field*: int32
    info*: c4m_style_t

  c4m_style_entry_t* = struct_c4m_style_entry_t
    ## From libcon4m/include/util/dt_styles.h:10:3
  struct_c4m_style_info_t* {.pure, inheritable, bycopy.} = object
    num_entries*: int64 ## From libcon4m/include/util/dt_styles.h:12:9
    styles*: ptr UncheckedArray[c4m_style_entry_t]

  c4m_style_info_t* = struct_c4m_style_info_t
    ## From libcon4m/include/util/dt_styles.h:15:3
  c4m_alignment_t* = enum_c4m_alignment_t ## From libcon4m/include/util/dt_styles.h:44:3
  c4m_dimspec_kind_t* = enum_c4m_dimspec_kind_t
    ## From libcon4m/include/util/dt_styles.h:60:3
  struct_border_theme_t* {.pure, inheritable, bycopy.} = object
    next_style*: ptr struct_border_theme_t
      ## From libcon4m/include/util/dt_styles.h:62:16
    name*: cstring
    horizontal_rule*: int32
    vertical_rule*: int32
    upper_left*: int32
    upper_right*: int32
    lower_left*: int32
    lower_right*: int32
    cross*: int32
    top_t*: int32
    bottom_t*: int32
    left_t*: int32
    right_t*: int32

  c4m_border_theme_t* = struct_border_theme_t
    ## From libcon4m/include/util/dt_styles.h:76:3
  c4m_border_set_t* = uint8 ## From libcon4m/include/util/dt_styles.h:78:17
  struct_c4m_render_style_t_dims_t* {.union, bycopy.} = object
    percent*: cfloat
    units*: uint64
    range*: array[2, int32]

  struct_c4m_render_style_t* {.pure, inheritable, bycopy.} = object
    name*: cstring ## From libcon4m/include/util/dt_styles.h:87:9
    border_theme*: ptr c4m_border_theme_t
    base_style*: c4m_style_t
    pad_color*: c4m_color_t
    dims*: struct_c4m_render_style_t_dims_t
    top_pad*: int8
    bottom_pad*: int8
    left_pad*: int8
    right_pad*: int8
    wrap*: int8
    alignment*: c4m_alignment_t
    dim_kind*: c4m_dimspec_kind_t
    borders*: c4m_border_set_t
    pad_color_set*: uint8
    disable_wrap*: uint8
    tpad_set*: uint8
    bpad_set*: uint8
    lpad_set*: uint8
    rpad_set*: uint8
    hang_set*: uint8

  c4m_render_style_t* = struct_c4m_render_style_t
    ## From libcon4m/include/util/dt_styles.h:116:3
  c4m_str_t* = struct_c4m_str_t ## From libcon4m/include/adts/dt_strings.h:20:3
  c4m_utf8_t* = c4m_str_t ## From libcon4m/include/adts/dt_strings.h:22:19
  c4m_utf32_t* = c4m_str_t ## From libcon4m/include/adts/dt_strings.h:23:19
  struct_break_info_st* {.pure, inheritable, bycopy.} = object
    num_slots*: int32 ## From libcon4m/include/adts/dt_strings.h:25:16
    num_breaks*: int32
    breaks*: ptr UncheckedArray[int32]

  c4m_break_info_t* = struct_break_info_st
    ## From libcon4m/include/adts/dt_strings.h:29:3
  struct_c4m_internal_string_st* {.pure, inheritable, bycopy.} = object
    base_data_type*: ptr c4m_dt_info_t ## From libcon4m/include/adts/dt_strings.h:32:8
    concrete_type*: ptr struct_c4m_type_t
    hash_cache_1*: uint64
    hash_cache_2*: uint64
    s*: c4m_str_t

  c4m_u8_state_t* = enum_c4m_u8_state_t ## From libcon4m/include/adts/dt_strings.h:46:3
  struct_c4m_flags_t* {.pure, inheritable, bycopy.} = object
    contents*: ptr uint64 ## From libcon4m/include/adts/dt_flags.h:4:9
    bit_modulus*: int32
    alloc_wordlen*: int32
    num_flags*: uint32

  c4m_flags_t* = struct_c4m_flags_t ## From libcon4m/include/adts/dt_flags.h:9:3
  struct_c4m_list_t* {.pure, inheritable, bycopy.} = object
    data*: ptr ptr int64 ## From libcon4m/include/adts/dt_lists.h:5:9
    append_ix*: int32
    length*: int32
    lock*: pthread_rwlock_t
    dont_acquire*: bool

  pthread_rwlock_t* = union_pthread_rwlock_t
    ## From /usr/include/bits/pthreadtypes.h:91:3
  c4m_list_t* = struct_c4m_list_t ## From libcon4m/include/adts/dt_lists.h:14:3
  c4m_stack_t* = struct_hatstack_t ## From libcon4m/include/adts/dt_lists.h:16:27
  struct_c4m_tree_node_t* {.pure, inheritable, bycopy.} = object
    children*: ptr ptr struct_c4m_tree_node_t
      ## From libcon4m/include/adts/dt_trees.h:5:16
    parent*: ptr struct_c4m_tree_node_t
    contents*: c4m_obj_t
    alloced_kids*: int32
    num_kids*: int32

  c4m_tree_node_t* = struct_c4m_tree_node_t ## From libcon4m/include/adts/dt_trees.h:11:3
  c4m_walker_fn* = proc(a0: ptr c4m_tree_node_t): void {.cdecl.}
    ## From libcon4m/include/adts/dt_trees.h:13:16
  struct_c4m_tpat_node_t* {.pure, inheritable, bycopy.} = object
    children*: ptr ptr struct_c4m_tpat_node_t
      ## From libcon4m/include/util/dt_tree_patterns.h:4:16
    contents*: c4m_obj_t
    min*: int64
    max*: int64
    num_kids*: uint64
    walk* {.bitsize: 1.}: cuint
    capture* {.bitsize: 1.}: cuint
    ignore_kids* {.bitsize: 1.}: cuint

  c4m_tpat_node_t* = struct_c4m_tpat_node_t
    ## From libcon4m/include/util/dt_tree_patterns.h:13:3
  c4m_pattern_fmt_fn* = proc(a0: pointer): ptr c4m_utf8_t {.cdecl.}
    ## From libcon4m/include/util/dt_tree_patterns.h:15:23
  c4m_type_hash_t* = uint64 ## From libcon4m/include/core/dt_types.h:5:18
  c4m_type_info_t* = struct_c4m_type_info_t ## From libcon4m/include/core/dt_types.h:27:3
  struct_c4m_type_info_t* {.pure, inheritable, bycopy.} = object
    name*: cstring ## From libcon4m/include/core/dt_types.h:21:16
    base_type*: ptr c4m_dt_info_t
    items*: ptr c4m_list_t
    tsi*: pointer
    flags*: uint64

  struct_tv_options_t* {.pure, inheritable, bycopy.} = object
    container_options*: ptr uint64 ## From libcon4m/include/core/dt_types.h:9:9
    value_type*: ptr struct_c4m_type_t
    props*: ptr c4m_dict_t

  tv_options_t* = struct_tv_options_t ## From libcon4m/include/core/dt_types.h:13:3
  c4m_type_t* = struct_c4m_type_t ## From libcon4m/include/core/dt_types.h:19:3
  c4m_type_exact_result_t* = enum_c4m_type_exact_result_t
    ## From libcon4m/include/core/dt_types.h:55:3
  c4m_next_typevar_fn* = proc(): uint64 {.cdecl.}
    ## From libcon4m/include/core/dt_types.h:57:20
  struct_c4m_type_universe_t* {.pure, inheritable, bycopy.} = object
    store*: crown_t ## From libcon4m/include/core/dt_types.h:59:9
    next_typeid*: Atomic[uint64]

  c4m_type_universe_t* = struct_c4m_type_universe_t
    ## From libcon4m/include/core/dt_types.h:62:3
  c4m_grid_t* = struct_c4m_grid_t ## From libcon4m/include/adts/dt_grids.h:122:27
  struct_c4m_grid_t* {.pure, inheritable, bycopy.} = object
    self*: ptr c4m_renderable_t ## From libcon4m/include/adts/dt_grids.h:175:8
    cells*: ptr ptr c4m_renderable_t
    col_props*: ptr c4m_dict_t
    row_props*: ptr c4m_dict_t
    td_tag_name*: cstring
    th_tag_name*: cstring
    num_cols*: int64
    num_rows*: int64
    spare_rows*: uint64
    width*: int16
    height*: int16
    row_cursor*: uint16
    col_cursor*: uint16
    header_cols*: int8
    header_rows*: int8
    stripe*: int8

  struct_c4m_renderable_t* {.pure, inheritable, bycopy.} = object
    container_tag*: cstring ## From libcon4m/include/adts/dt_grids.h:162:9
    current_style*: ptr c4m_render_style_t
    render_cache*: ptr c4m_list_t
    raw_item*: c4m_obj_t
    start_col*: int64
    start_row*: int64
    end_col*: int64
    end_row*: int64
    render_width*: uint64
    render_height*: uint64

  c4m_renderable_t* = struct_c4m_renderable_t
    ## From libcon4m/include/adts/dt_grids.h:173:3
  struct_c4m_buf_t* {.pure, inheritable, bycopy.} = object
    data*: cstring ## From libcon4m/include/adts/dt_buffers.h:5:9
    flags*: int32
    byte_len*: int32
    alloc_len*: int32

  c4m_buf_t* = struct_c4m_buf_t ## From libcon4m/include/adts/dt_buffers.h:10:3
  c4m_party_enum* = enum_c4m_party_enum ## From libcon4m/include/io/dt_io.h:14:3
  c4m_sb_cb_t* =
    proc(a0: pointer, a1: pointer, a2: cstring, a3: csize_t): void {.cdecl.}
    ## From libcon4m/include/io/dt_io.h:16:16
  c4m_accept_decl* = proc(
    a0: pointer, a1: cint, a2: ptr struct_sockaddr, a3: ptr socklen_t
  ): void {.cdecl.} ## From libcon4m/include/io/dt_io.h:17:16
  struct_sockaddr* {.pure, inheritable, bycopy.} = object
    sa_family*: sa_family_t ## From /usr/include/bits/socket.h:184:39
    sa_data*: array[14, cschar]

  socklen_t* = compiler_socklen_t ## From /usr/include/unistd.h:274:21
  c4m_progress_decl* = proc(a0: pointer): bool {.cdecl.}
    ## From libcon4m/include/io/dt_io.h:18:16
  struct_c4m_sb_msg_t* {.pure, inheritable, bycopy.} = object
    next*: ptr struct_c4m_sb_msg_t ## From libcon4m/include/io/dt_io.h:30:16
    len*: csize_t
    data*: array[4097, cschar]

  c4m_sb_msg_t* = struct_c4m_sb_msg_t ## From libcon4m/include/io/dt_io.h:34:3
  struct_c4m_sb_heap_t* {.pure, inheritable, bycopy.} = object
    next*: ptr struct_c4m_sb_heap_t ## From libcon4m/include/io/dt_io.h:48:16
    cur_cell*: csize_t
    dummy*: uint32
    cells*: ptr UncheckedArray[c4m_sb_msg_t]

  c4m_sb_heap_t* = struct_c4m_sb_heap_t ## From libcon4m/include/io/dt_io.h:53:3
  struct_c4m_subscription_t* {.pure, inheritable, bycopy.} = object
    next*: ptr struct_c4m_subscription_t ## From libcon4m/include/io/dt_io.h:64:16
    subscriber*: ptr struct_c4m_party_t
    paused*: bool

  struct_c4m_party_t* {.pure, inheritable, bycopy.} = object
    info*: c4m_party_info_t ## From libcon4m/include/io/dt_io.h:170:16
    next_reader*: ptr struct_c4m_party_t
    next_writer*: ptr struct_c4m_party_t
    next_loner*: ptr struct_c4m_party_t
    extra*: pointer
    c4m_party_type*: c4m_party_enum
    found_errno*: cint
    open_for_write*: bool
    open_for_read*: bool
    can_read_from_it*: bool
    can_write_to_it*: bool
    close_on_destroy*: bool
    stop_on_close*: bool

  c4m_subscription_t* = struct_c4m_subscription_t
    ## From libcon4m/include/io/dt_io.h:68:3
  struct_c4m_party_fd_t* {.pure, inheritable, bycopy.} = object
    first_msg*: ptr c4m_sb_msg_t ## From libcon4m/include/io/dt_io.h:77:9
    last_msg*: ptr c4m_sb_msg_t
    subscribers*: ptr c4m_subscription_t
    fd*: cint
    proxy_close*: bool

  c4m_party_fd_t* = struct_c4m_party_fd_t ## From libcon4m/include/io/dt_io.h:83:3
  struct_c4m_party_listener_t* {.pure, inheritable, bycopy.} = object
    accept_cb*: c4m_accept_decl ## From libcon4m/include/io/dt_io.h:88:9
    fd*: cint
    saved_flags*: cint

  c4m_party_listener_t* = struct_c4m_party_listener_t
    ## From libcon4m/include/io/dt_io.h:92:3
  struct_c4m_party_instr_t* {.pure, inheritable, bycopy.} = object
    strbuf*: cstring ## From libcon4m/include/io/dt_io.h:97:9
    free_on_close*: bool
    len*: csize_t
    close_fd_when_done*: bool

  c4m_party_instr_t* = struct_c4m_party_instr_t ## From libcon4m/include/io/dt_io.h:102:3
  struct_c4m_party_outstr_t* {.pure, inheritable, bycopy.} = object
    strbuf*: cstring ## From libcon4m/include/io/dt_io.h:108:9
    tag*: cstring
    len*: csize_t
    ix*: csize_t
    step*: csize_t

  c4m_party_outstr_t* = struct_c4m_party_outstr_t
    ## From libcon4m/include/io/dt_io.h:114:3
  struct_c4m_party_callback_t* {.pure, inheritable, bycopy.} = object
    callback*: c4m_sb_cb_t ## From libcon4m/include/io/dt_io.h:121:9

  c4m_party_callback_t* = struct_c4m_party_callback_t
    ## From libcon4m/include/io/dt_io.h:123:3
  union_c4m_party_info_t* {.union, bycopy.} = object
    rstrinfo*: c4m_party_instr_t ## From libcon4m/include/io/dt_io.h:128:9
    wstrinfo*: c4m_party_outstr_t
    fdinfo*: c4m_party_fd_t
    listenerinfo*: c4m_party_listener_t
    cbinfo*: c4m_party_callback_t

  c4m_party_info_t* = union_c4m_party_info_t ## From libcon4m/include/io/dt_io.h:134:3
  c4m_party_t* = struct_c4m_party_t ## From libcon4m/include/io/dt_io.h:184:3
  struct_c4m_monitor_t* {.pure, inheritable, bycopy.} = object
    next*: ptr struct_c4m_monitor_t ## From libcon4m/include/io/dt_io.h:192:16
    stdin_fd_party*: ptr c4m_party_t
    stdout_fd_party*: ptr c4m_party_t
    stderr_fd_party*: ptr c4m_party_t
    exit_status*: cint
    pid*: pid_t
    shutdown_when_closed*: bool
    closed*: bool
    found_errno*: cint
    term_signal*: cint

  c4m_monitor_t* = struct_c4m_monitor_t ## From libcon4m/include/io/dt_io.h:203:3
  struct_c4m_one_capture_t* {.pure, inheritable, bycopy.} = object
    tag*: cstring ## From libcon4m/include/io/dt_io.h:205:9
    contents*: cstring
    len*: cint

  c4m_one_capture_t* = struct_c4m_one_capture_t ## From libcon4m/include/io/dt_io.h:209:3
  struct_c4m_capture_result_t* {.pure, inheritable, bycopy.} = object
    captures*: ptr c4m_one_capture_t ## From libcon4m/include/io/dt_io.h:211:9
    inited*: bool
    num_captures*: cint

  c4m_capture_result_t* = struct_c4m_capture_result_t
    ## From libcon4m/include/io/dt_io.h:215:3
  struct_c4m_switchboard_t* {.pure, inheritable, bycopy.} = object
    parties_for_reading*: ptr c4m_party_t ## From libcon4m/include/io/dt_io.h:221:16
    parties_for_writing*: ptr c4m_party_t
    party_loners*: ptr c4m_party_t
    pid_watch_list*: ptr c4m_monitor_t
    freelist*: ptr c4m_sb_msg_t
    heap*: ptr c4m_sb_heap_t
    extra*: pointer
    io_timeout_ptr*: ptr struct_timeval
    io_timeout*: struct_timeval
    progress_callback*: c4m_progress_decl
    progress_on_timeout_only*: bool
    done*: bool
    readset*: fd_set
    writeset*: fd_set
    max_fd*: cint
    fds_ready*: cint
    heap_elems*: csize_t
    ignore_running_procs_on_shutdown*: bool

  struct_timeval* {.pure, inheritable, bycopy.} = object
    tv_sec*: compiler_time_t ## From /usr/include/bits/types/struct_timeval.h:8:8
    tv_usec*: compiler_suseconds_t

  fd_set* = struct_fd_set ## From /usr/include/sys/select.h:70:5
  c4m_switchboard_t* = struct_c4m_switchboard_t ## From libcon4m/include/io/dt_io.h:240:3
  struct_c4m_subproc_t* {.pure, inheritable, bycopy.} = object
    startup_callback*: proc(a0: pointer): void {.cdecl.}
      ## From libcon4m/include/io/dt_io.h:242:9
    cmd*: cstring
    argv*: ptr cstring
    envp*: ptr cstring
    path*: cstring
    sb*: c4m_switchboard_t
    run*: bool
    child_termcap*: ptr struct_termios
    deferred_cbs*: ptr struct_c4m_dcb_t
    parent_termcap*: ptr struct_termios
    result*: c4m_capture_result_t
    saved_termcap*: struct_termios
    signal_fd*: cint
    pty_fd*: cint
    pty_stdin_pipe*: bool
    proxy_stdin_close*: bool
    use_pty*: bool
    str_waiting*: bool
    passthrough*: cschar
    pt_all_to_stdout*: bool
    capture*: cschar
    combine_captures*: bool
    str_stdin*: c4m_party_t
    parent_stdin*: c4m_party_t
    parent_stdout*: c4m_party_t
    parent_stderr*: c4m_party_t
    subproc_stdin*: c4m_party_t
    subproc_stdout*: c4m_party_t
    subproc_stderr*: c4m_party_t
    capture_stdin*: c4m_party_t
    capture_stdout*: c4m_party_t
    capture_stderr*: c4m_party_t

  struct_c4m_dcb_t* {.pure, inheritable, bycopy.} = object
    next*: ptr struct_c4m_dcb_t ## From libcon4m/include/io/dt_io.h:291:16
    to_free*: ptr c4m_party_t
    which*: uint8
    cb*: c4m_sb_cb_t

  c4m_subproc_t* = struct_c4m_subproc_t ## From libcon4m/include/io/dt_io.h:276:3
  c4m_accept_cb_t* = proc(
    a0: ptr struct_c4m_switchboard_t,
    a1: cint,
    a2: ptr struct_sockaddr,
    a3: ptr socklen_t,
  ): void {.cdecl.} ## From libcon4m/include/io/dt_io.h:285:16
  c4m_progress_cb_t* = proc(a0: ptr struct_c4m_switchboard_t): bool {.cdecl.}
    ## From libcon4m/include/io/dt_io.h:289:16
  c4m_deferred_cb_t* = struct_c4m_dcb_t ## From libcon4m/include/io/dt_io.h:296:3
  EVP_MD_CTX* = pointer ## From libcon4m/include/crypto/dt_crypto.h:4:15
  EVP_MD* = pointer ## From libcon4m/include/crypto/dt_crypto.h:5:15
  OSSL_PARAM* = pointer ## From libcon4m/include/crypto/dt_crypto.h:6:15
  struct_c4m_sha_t* {.pure, inheritable, bycopy.} = object
    digest*: ptr c4m_buf_t ## From libcon4m/include/crypto/dt_crypto.h:8:9
    openssl_ctx*: EVP_MD_CTX

  c4m_sha_t* = struct_c4m_sha_t ## From libcon4m/include/crypto/dt_crypto.h:11:3
  c4m_exception_t* = struct_c4m_exception_st
    ## From libcon4m/include/core/dt_exceptions.h:4:39
  struct_c4m_exception_st* {.pure, inheritable, bycopy.} = object
    msg*: ptr c4m_utf8_t ## From libcon4m/include/core/dt_exceptions.h:7:8
    context*: ptr c4m_obj_t
    previous*: ptr c4m_exception_t
    code*: int64
    file*: cstring
    line*: uint64

  c4m_exception_frame_t* = struct_c4m_exception_frame_st
    ## From libcon4m/include/core/dt_exceptions.h:5:39
  struct_c4m_exception_frame_st* {.pure, inheritable, bycopy.} = object
    buf*: ptr jmp_buf ## From libcon4m/include/core/dt_exceptions.h:19:8
    exception*: ptr c4m_exception_t
    next*: ptr c4m_exception_frame_t

  jmp_buf* = array[1, struct_jmp_buf_tag] ## From /usr/include/setjmp.h:32:30
  struct_c4m_exception_stack_t* {.pure, inheritable, bycopy.} = object
    c_trace*: ptr c4m_grid_t ## From libcon4m/include/core/dt_exceptions.h:25:9
    top*: ptr c4m_exception_frame_t
    free_frames*: ptr c4m_exception_frame_t

  c4m_exception_stack_t* = struct_c4m_exception_stack_t
    ## From libcon4m/include/core/dt_exceptions.h:29:3
  struct_c4m_mixed_t* {.pure, inheritable, bycopy.} = object
    held_type*: ptr c4m_type_t ## From libcon4m/include/adts/dt_mixed.h:5:9
    held_value*: pointer

  c4m_mixed_t* = struct_c4m_mixed_t ## From libcon4m/include/adts/dt_mixed.h:10:3
  struct_c4m_tuple_t* {.pure, inheritable, bycopy.} = object
    items*: ptr pointer ## From libcon4m/include/adts/dt_tuples.h:5:9
    num_items*: cint

  c4m_tuple_t* = struct_c4m_tuple_t ## From libcon4m/include/adts/dt_tuples.h:8:3
  c4m_cookie_t* = struct_c4m_cookie_t ## From libcon4m/include/adts/dt_streams.h:24:3
  struct_c4m_cookie_t* {.pure, inheritable, bycopy.} = object
    object_field*: c4m_obj_t ## From libcon4m/include/adts/dt_streams.h:13:16
    extra*: cstring
    position*: int64
    eof*: int64
    flags*: int64
    ptr_setup*: c4m_stream_setup_fn
    ptr_read*: c4m_stream_read_fn
    ptr_write*: c4m_stream_write_fn
    ptr_close*: c4m_stream_close_fn
    ptr_seek*: c4m_stream_seek_fn

  c4m_stream_setup_fn* = proc(a0: ptr c4m_cookie_t): void {.cdecl.}
    ## From libcon4m/include/adts/dt_streams.h:7:16
  c4m_stream_read_fn* =
    proc(a0: ptr c4m_cookie_t, a1: cstring, a2: int64): csize_t {.cdecl.}
    ## From libcon4m/include/adts/dt_streams.h:8:18
  c4m_stream_write_fn* =
    proc(a0: ptr c4m_cookie_t, a1: cstring, a2: int64): csize_t {.cdecl.}
    ## From libcon4m/include/adts/dt_streams.h:9:18
  c4m_stream_close_fn* = proc(a0: ptr c4m_cookie_t): void {.cdecl.}
    ## From libcon4m/include/adts/dt_streams.h:10:16
  c4m_stream_seek_fn* = proc(a0: ptr c4m_cookie_t, a1: int64): bool {.cdecl.}
    ## From libcon4m/include/adts/dt_streams.h:11:16
  struct_c4m_stream_t_contents_t* {.union, bycopy.} = object
    f*: ptr FILE
    cookie*: ptr c4m_cookie_t

  struct_c4m_stream_t* {.pure, inheritable, bycopy.} = object
    contents*: struct_c4m_stream_t_contents_t
      ## From libcon4m/include/adts/dt_streams.h:26:9
    flags*: int64

  c4m_stream_t* = struct_c4m_stream_t ## From libcon4m/include/adts/dt_streams.h:32:3
  struct_c4m_fmt_spec_t* {.pure, inheritable, bycopy.} = object
    fill*: c4m_codepoint_t ## From libcon4m/include/util/dt_format.h:4:16
    width*: int64
    precision*: int64
    kind* {.bitsize: 2.}: cuint
    align* {.bitsize: 2.}: cuint
    sign* {.bitsize: 2.}: cuint
    sep* {.bitsize: 2.}: cuint
    empty* {.bitsize: 1.}: cuint
    type_field*: c4m_codepoint_t

  c4m_fmt_spec_t* = struct_c4m_fmt_spec_t ## From libcon4m/include/util/dt_format.h:14:3
  struct_c4m_fmt_info_t_reference_t* {.union, bycopy.} = object
    name*: cstring
    position*: int64

  struct_c4m_fmt_info_t* {.pure, inheritable, bycopy.} = object
    reference*: struct_c4m_fmt_info_t_reference_t
      ## From libcon4m/include/util/dt_format.h:16:16
    next*: ptr struct_c4m_fmt_info_t
    spec*: c4m_fmt_spec_t
    start*: cint
    end_field*: cint

  c4m_fmt_info_t* = struct_c4m_fmt_info_t ## From libcon4m/include/util/dt_format.h:25:3
  c4m_token_kind_t* = enum_c4m_token_kind_t
    ## From libcon4m/include/compiler/dt_lex.h:91:3
  struct_c4m_token_t* {.pure, inheritable, bycopy.} = object
    module*: ptr struct_c4m_module_compile_ctx
      ## From libcon4m/include/compiler/dt_lex.h:93:9
    start_ptr*: ptr c4m_codepoint_t
    end_ptr*: ptr c4m_codepoint_t
    literal_modifier*: ptr c4m_utf8_t
    literal_value*: pointer
    text*: ptr c4m_utf8_t
    syntax*: c4m_lit_syntax_t
    kind*: c4m_token_kind_t
    token_id*: cint
    line_no*: cint
    line_offset*: cint
    child_ix*: uint32
    adjustment*: uint8

  struct_c4m_module_compile_ctx* {.pure, inheritable, bycopy.} = object
    module*: ptr c4m_str_t ## From libcon4m/include/compiler/dt_module.h:15:16
    path*: ptr c4m_str_t
    package*: ptr c4m_str_t
    loaded_from*: ptr c4m_str_t
    raw*: ptr c4m_utf32_t
    tokens*: ptr c4m_list_t
    parse_tree*: ptr c4m_tree_node_t
    errors*: ptr c4m_list_t
    global_scope*: ptr c4m_scope_t
    module_scope*: ptr c4m_scope_t
    attribute_scope*: ptr c4m_scope_t
    imports*: ptr c4m_scope_t
    parameters*: ptr c4m_dict_t
    local_confspecs*: ptr c4m_spec_t
    cfg*: ptr c4m_cfg_node_t
    short_doc*: ptr c4m_utf8_t
    long_doc*: ptr c4m_utf8_t
    fn_def_syms*: ptr c4m_list_t
    module_object*: ptr c4m_zmodule_info_t
    call_patch_locs*: ptr c4m_list_t
    callback_literals*: ptr c4m_list_t
    extern_decls*: ptr c4m_list_t
    module_id*: uint64
    static_size*: int32
    num_params*: uint32
    local_module_id*: uint32
    fatal_errors* {.bitsize: 1.}: cuint
    status*: c4m_module_compile_status

  c4m_token_t* = struct_c4m_token_t ## From libcon4m/include/compiler/dt_lex.h:111:3
  c4m_compile_error_t* = enum_c4m_compile_error_t
    ## From libcon4m/include/compiler/dt_errors.h:198:3
  c4m_err_severity_t* = enum_c4m_err_severity_t
    ## From libcon4m/include/compiler/dt_errors.h:206:3
  struct_c4m_compile_error* {.pure, inheritable, bycopy.} = object
    code*: c4m_compile_error_t ## From libcon4m/include/compiler/dt_errors.h:208:9
    current_token*: ptr c4m_token_t
    long_info*: ptr c4m_str_t
    num_args*: int32
    severity*: c4m_err_severity_t
    msg_parameters*: ptr UncheckedArray[ptr c4m_str_t]

  c4m_compile_error* = struct_c4m_compile_error
    ## From libcon4m/include/compiler/dt_errors.h:224:3
  c4m_node_kind_t* = enum_c4m_node_kind_t
    ## From libcon4m/include/compiler/dt_parse.h:86:3
  c4m_operator_t* = enum_c4m_operator_t
    ## From libcon4m/include/compiler/dt_parse.h:106:3
  struct_c4m_comment_node_t* {.pure, inheritable, bycopy.} = object
    comment_tok*: ptr c4m_token_t ## From libcon4m/include/compiler/dt_parse.h:108:9
    sibling_id*: cint

  c4m_comment_node_t* = struct_c4m_comment_node_t
    ## From libcon4m/include/compiler/dt_parse.h:111:3
  struct_c4m_pnode_t* {.pure, inheritable, bycopy.} = object
    token*: ptr c4m_token_t ## From libcon4m/include/compiler/dt_parse.h:113:9
    short_doc*: ptr c4m_token_t
    long_doc*: ptr c4m_token_t
    comments*: ptr c4m_list_t
    value*: ptr c4m_obj_t
    extra_info*: pointer
    static_scope*: ptr struct_c4m_scope_t
    type_field*: ptr c4m_type_t
    kind*: c4m_node_kind_t
    total_kids*: cint
    sibling_id*: cint
    have_value*: bool

  struct_c4m_scope_t* {.pure, inheritable, bycopy.} = object
    parent*: ptr struct_c4m_scope_t ## From libcon4m/include/compiler/dt_scopes.h:108:16
    symbols*: ptr c4m_dict_t
    kind*: enum_c4m_scope_kind

  c4m_pnode_t* = struct_c4m_pnode_t ## From libcon4m/include/compiler/dt_parse.h:142:3
  c4m_symbol_kind* = enum_c4m_symbol_kind
    ## From libcon4m/include/compiler/dt_scopes.h:14:3
  c4m_scope_kind* = enum_c4m_scope_kind
    ## From libcon4m/include/compiler/dt_scopes.h:44:3
  struct_c4m_module_info_t* {.pure, inheritable, bycopy.} = object
    specified_module*: ptr c4m_utf8_t ## From libcon4m/include/compiler/dt_scopes.h:48:9
    specified_package*: ptr c4m_utf8_t
    specified_uri*: ptr c4m_utf8_t

  c4m_module_info_t* = struct_c4m_module_info_t
    ## From libcon4m/include/compiler/dt_scopes.h:52:3
  struct_c4m_symbol_t* {.pure, inheritable, bycopy.} = object
    type_declaration_node*: ptr c4m_tree_node_t
      ## From libcon4m/include/compiler/dt_scopes.h:54:16
    other_info*: pointer
    sym_defs*: ptr c4m_list_t
    sym_uses*: ptr c4m_list_t
    linked_symbol*: ptr struct_c4m_symbol_t
    name*: ptr c4m_utf8_t
    declaration_node*: ptr c4m_tree_node_t
    value_node*: ptr c4m_tree_node_t
    path*: ptr c4m_utf8_t
    type_field*: ptr c4m_type_t
    my_scope*: ptr struct_c4m_scope_t
    cfg_kill_node*: pointer
    value*: c4m_obj_t
    kind*: c4m_symbol_kind
    static_offset*: uint32
    local_module_id*: uint32
    flags*: uint32

  c4m_symbol_t* = struct_c4m_symbol_t ## From libcon4m/include/compiler/dt_scopes.h:95:3
  struct_c4m_module_param_info_t* {.pure, inheritable, bycopy.} = object
    short_doc*: ptr c4m_utf8_t ## From libcon4m/include/compiler/dt_scopes.h:97:9
    long_doc*: ptr c4m_utf8_t
    linked_symbol*: ptr c4m_symbol_t
    callback*: c4m_obj_t
    validator*: c4m_obj_t
    default_value*: c4m_obj_t
    param_index*: cuint
    have_default* {.bitsize: 1.}: cuint

  c4m_module_param_info_t* = struct_c4m_module_param_info_t
    ## From libcon4m/include/compiler/dt_scopes.h:106:3
  c4m_scope_t* = struct_c4m_scope_t ## From libcon4m/include/compiler/dt_scopes.h:112:3
  c4m_ffi_abi* = enum_c4m_ffi_abi ## From libcon4m/include/core/dt_ffi.h:22:3
  struct_c4m_ffi_type* {.pure, inheritable, bycopy.} = object
    size*: csize_t ## From libcon4m/include/core/dt_ffi.h:25:16
    alignment*: cushort
    ffitype*: cushort
    elements*: ptr ptr struct_c4m_ffi_type

  c4m_ffi_type* = struct_c4m_ffi_type ## From libcon4m/include/core/dt_ffi.h:30:3
  struct_c4m_ffi_cif* {.pure, inheritable, bycopy.} = object
    abi*: c4m_ffi_abi ## From libcon4m/include/core/dt_ffi.h:33:9
    nargs*: cuint
    arg_types*: ptr ptr c4m_ffi_type
    rtype*: ptr c4m_ffi_type
    bytes*: cuint
    flags*: cuint
    extra_cif1*: uint64
    extra_cif2*: uint64

  c4m_ffi_cif* = struct_c4m_ffi_cif ## From libcon4m/include/core/dt_ffi.h:47:3
  struct_c4m_zffi_cif* {.pure, inheritable, bycopy.} = object
    fptr*: pointer ## From libcon4m/include/core/dt_ffi.h:49:9
    local_name*: ptr c4m_utf8_t
    extern_name*: ptr c4m_utf8_t
    str_convert*: uint64
    hold_info*: uint64
    alloc_info*: uint64
    args*: ptr ptr c4m_ffi_type
    ret*: ptr c4m_ffi_type
    cif*: c4m_ffi_cif

  c4m_zffi_cif* = struct_c4m_zffi_cif ## From libcon4m/include/core/dt_ffi.h:59:3
  c4m_ffi_status* = enum_c4m_ffi_status ## From libcon4m/include/core/dt_ffi.h:66:3
  struct_c4m_ffi_decl_t* {.pure, inheritable, bycopy.} = object
    short_doc*: ptr c4m_utf8_t ## From libcon4m/include/core/dt_ffi.h:68:16
    long_doc*: ptr c4m_utf8_t
    local_name*: ptr c4m_utf8_t
    local_params*: ptr struct_c4m_sig_info_t
    external_name*: ptr c4m_utf8_t
    dll_list*: ptr c4m_list_t
    external_params*: ptr uint8
    external_return_type*: uint8
    skip_boxes*: bool
    cif*: c4m_zffi_cif
    num_ext_params*: cint
    global_ffi_call_ix*: cint

  struct_c4m_sig_info_t* {.pure, inheritable, bycopy.} = object
    full_type*: ptr c4m_type_t ## From libcon4m/include/core/dt_ufi.h:11:16
    param_info*: ptr c4m_fn_param_info_t
    fn_scope*: ptr c4m_scope_t
    formals*: ptr c4m_scope_t
    return_info*: c4m_fn_param_info_t
    num_params*: cint
    pure* {.bitsize: 1.}: cuint
    void_return* {.bitsize: 1.}: cuint

  c4m_ffi_decl_t* = struct_c4m_ffi_decl_t ## From libcon4m/include/core/dt_ffi.h:81:3
  struct_c4m_fn_param_info_t* {.pure, inheritable, bycopy.} = object
    name*: ptr c4m_utf8_t ## From libcon4m/include/core/dt_ufi.h:4:9
    type_field*: ptr c4m_type_t
    ffi_holds* {.bitsize: 1.}: cuint
    ffi_allocs* {.bitsize: 1.}: cuint

  c4m_fn_param_info_t* = struct_c4m_fn_param_info_t
    ## From libcon4m/include/core/dt_ufi.h:9:3
  c4m_sig_info_t* = struct_c4m_sig_info_t ## From libcon4m/include/core/dt_ufi.h:20:3
  struct_c4m_fn_decl_t* {.pure, inheritable, bycopy.} = object
    short_doc*: ptr c4m_utf8_t ## From libcon4m/include/core/dt_ufi.h:22:9
    long_doc*: ptr c4m_utf8_t
    signature_info*: ptr c4m_sig_info_t
    cfg*: ptr struct_c4m_cfg_node_t
    frame_size*: int32
    sc_lock_offset*: int32
    sc_bool_offset*: int32
    sc_memo_offset*: int32
    local_id*: int32
    offset*: int32
    module_id*: int32
    private* {.bitsize: 1.}: cuint
    once* {.bitsize: 1.}: cuint

  struct_c4m_cfg_node_t_contents_t* {.union, bycopy.} = object
    block_entrance*: c4m_cfg_block_enter_info_t
    block_exit*: c4m_cfg_block_exit_info_t
    branches*: c4m_cfg_branch_info_t
    flow*: c4m_cfg_flow_info_t
    jump*: c4m_cfg_jump_info_t

  struct_c4m_cfg_node_t* {.pure, inheritable, bycopy.} = object
    reference_location*: ptr c4m_tree_node_t
      ## From libcon4m/include/compiler/dt_cfgs.h:54:8
    parent*: ptr c4m_cfg_node_t
    starting_liveness_info*: ptr c4m_dict_t
    starting_sometimes*: ptr c4m_list_t
    liveness_info*: ptr c4m_dict_t
    sometimes_live*: ptr c4m_list_t
    contents*: struct_c4m_cfg_node_t_contents_t
    kind*: c4m_cfg_node_type
    use_without_def* {.bitsize: 1.}: cuint
    reached* {.bitsize: 1.}: cuint

  c4m_fn_decl_t* = struct_c4m_fn_decl_t ## From libcon4m/include/core/dt_ufi.h:50:3
  struct_c4m_funcinfo_t_implementation_t* {.union, bycopy.} = object
    ffi_interface*: ptr c4m_ffi_decl_t
    local_interface*: ptr c4m_fn_decl_t

  struct_c4m_funcinfo_t* {.pure, inheritable, bycopy.} = object
    implementation*: struct_c4m_funcinfo_t_implementation_t
      ## From libcon4m/include/core/dt_ufi.h:52:16
    ffi* {.bitsize: 1.}: cuint
    va* {.bitsize: 1.}: cuint

  c4m_funcinfo_t* = struct_c4m_funcinfo_t ## From libcon4m/include/core/dt_ufi.h:60:3
  c4m_zop_t* = enum_c4m_zop_t ## From libcon4m/include/core/dt_vm.h:338:3
  struct_c4m_zinstruction_t* {.pure, inheritable, bycopy.} = object
    op*: c4m_zop_t ## From libcon4m/include/core/dt_vm.h:348:9
    pad*: uint8
    module_id*: int32
    line_no*: int32
    arg*: int32
    immediate*: int64
    type_info*: ptr c4m_type_t

  c4m_zinstruction_t* = struct_c4m_zinstruction_t
    ## From libcon4m/include/core/dt_vm.h:356:3
  struct_c4m_zcallback_t* {.pure, inheritable, bycopy.} = object
    tid*: ptr c4m_type_t ## From libcon4m/include/core/dt_vm.h:358:9
    impl*: int64
    nameoffset*: int64
    mid*: int32
    ffi*: bool

  c4m_zcallback_t* = struct_c4m_zcallback_t ## From libcon4m/include/core/dt_vm.h:366:3
  struct_c4m_value_t* {.pure, inheritable, bycopy.} = object
    obj*: c4m_obj_t ## From libcon4m/include/core/dt_vm.h:374:16

  c4m_value_t* = struct_c4m_value_t ## From libcon4m/include/core/dt_vm.h:376:3
  union_c4m_stack_value_t* {.union, bycopy.} = object
    vptr*: pointer ## From libcon4m/include/core/dt_vm.h:380:15
    callback*: ptr c4m_zcallback_t
    lvalue*: ptr c4m_value_t
    cptr*: cstring
    fp*: ptr union_c4m_stack_value_t
    rvalue*: c4m_value_t
    static_ptr*: uint64
    uint*: uint64
    sint*: int64
    box*: c4m_box_t
    dbl*: cdouble
    boolean*: bool

  c4m_stack_value_t* = union_c4m_stack_value_t
    ## From libcon4m/include/core/dt_vm.h:395:3
  c4m_zffi_info_t* = struct_c4m_ffi_decl_t ## From libcon4m/include/core/dt_vm.h:398:31
  struct_c4m_zsymbol_t* {.pure, inheritable, bycopy.} = object
    tid*: ptr c4m_type_t ## From libcon4m/include/core/dt_vm.h:400:9
    offset*: int64

  c4m_zsymbol_t* = struct_c4m_zsymbol_t ## From libcon4m/include/core/dt_vm.h:403:3
  struct_c4m_zfn_info_t* {.pure, inheritable, bycopy.} = object
    funcname*: ptr c4m_str_t ## From libcon4m/include/core/dt_vm.h:405:9
    syms*: ptr c4m_dict_t
    sym_types*: ptr c4m_list_t
    tid*: ptr c4m_type_t
    shortdoc*: ptr c4m_str_t
    longdoc*: ptr c4m_str_t
    mid*: int32
    offset*: int32
    size*: int32
    static_lock*: int32

  c4m_zfn_info_t* = struct_c4m_zfn_info_t ## From libcon4m/include/core/dt_vm.h:429:3
  struct_c4m_zparam_info_t* {.pure, inheritable, bycopy.} = object
    attr*: ptr c4m_str_t ## From libcon4m/include/core/dt_vm.h:431:9
    tid*: ptr c4m_type_t
    shortdoc*: ptr c4m_str_t
    longdoc*: ptr c4m_str_t
    offset*: int64
    default_value*: c4m_value_t
    have_default*: bool
    is_private*: bool
    v_fn_ix*: int32
    v_native*: bool
    i_fn_ix*: int32
    i_native*: bool
    userparam*: c4m_value_t

  c4m_zparam_info_t* = struct_c4m_zparam_info_t
    ## From libcon4m/include/core/dt_vm.h:445:3
  struct_c4m_zmodule_info_t* {.pure, inheritable, bycopy.} = object
    modname*: ptr c4m_str_t ## From libcon4m/include/core/dt_vm.h:447:9
    authority*: ptr c4m_str_t
    path*: ptr c4m_str_t
    package*: ptr c4m_str_t
    source*: ptr c4m_str_t
    version*: ptr c4m_str_t
    shortdoc*: ptr c4m_str_t
    longdoc*: ptr c4m_str_t
    datasyms*: ptr c4m_dict_t
    parameters*: ptr c4m_list_t
    instructions*: ptr c4m_list_t
    module_hash*: uint64
    module_id*: int32
    module_var_size*: int32
    init_size*: int32

  c4m_zmodule_info_t* = struct_c4m_zmodule_info_t
    ## From libcon4m/include/core/dt_vm.h:463:3
  struct_c4m_zobject_file_t* {.pure, inheritable, bycopy.} = object
    zero_magic*: uint64 ## From libcon4m/include/core/dt_vm.h:465:9
    static_data*: ptr c4m_buf_t
    marshaled_consts*: ptr c4m_buf_t
    module_contents*: ptr c4m_list_t
    func_info*: ptr c4m_list_t
    ffi_info*: ptr c4m_list_t
    zc_object_vers*: uint32
    num_const_objs*: int32
    entrypoint*: int32
    next_entrypoint*: int32

  c4m_zobject_file_t* = struct_c4m_zobject_file_t
    ## From libcon4m/include/core/dt_vm.h:477:3
  struct_c4m_vmframe_t* {.pure, inheritable, bycopy.} = object
    call_module*: ptr c4m_zmodule_info_t ## From libcon4m/include/core/dt_vm.h:479:9
    targetmodule*: ptr c4m_zmodule_info_t
    targetfunc*: ptr c4m_zfn_info_t
    calllineno*: int32
    targetline*: int32

  c4m_vmframe_t* = struct_c4m_vmframe_t ## From libcon4m/include/core/dt_vm.h:485:3
  struct_c4m_attr_contents_t* {.pure, inheritable, bycopy.} = object
    lastset*: ptr c4m_zinstruction_t ## From libcon4m/include/core/dt_vm.h:487:9
    contents*: c4m_value_t
    is_set*: bool
    locked*: bool
    lock_on_write*: bool
    module_lock*: int32
    override*: bool

  c4m_attr_contents_t* = struct_c4m_attr_contents_t
    ## From libcon4m/include/core/dt_vm.h:495:3
  struct_c4m_docs_container_t* {.pure, inheritable, bycopy.} = object
    shortdoc*: ptr c4m_str_t ## From libcon4m/include/core/dt_vm.h:497:9
    longdoc*: ptr c4m_str_t

  c4m_docs_container_t* = struct_c4m_docs_container_t
    ## From libcon4m/include/core/dt_vm.h:500:3
  struct_c4m_vm_t_anon0_t* {.union, bycopy.} = object
    u*: uint64
    p*: pointer

  struct_c4m_vm_t* {.pure, inheritable, bycopy.} = object
    obj*: ptr c4m_zobject_file_t ## From libcon4m/include/core/dt_vm.h:503:9
    anon0*: struct_c4m_vm_t_anon0_t
    const_pool*: ptr union_23646
    module_allocations*: ptr ptr c4m_value_t
    attrs*: ptr c4m_dict_t
    all_sections*: ptr c4m_set_t
    section_docs*: ptr c4m_dict_t
    ffi_info*: ptr c4m_list_t
    ffi_info_entries*: cint
    using_attrs*: bool

  c4m_vm_t* = struct_c4m_vm_t ## From libcon4m/include/core/dt_vm.h:524:3
  struct_c4m_vmthread_t* {.pure, inheritable, bycopy.} = object
    vm*: ptr c4m_vm_t ## From libcon4m/include/core/dt_vm.h:526:9
    sp*: ptr c4m_stack_value_t
    fp*: ptr c4m_stack_value_t
    const_base*: cstring
    current_module*: ptr c4m_zmodule_info_t
    thread_arena*: ptr c4m_arena_t
    frame_stack*: array[100, c4m_vmframe_t]
    stack*: array[131072, c4m_stack_value_t]
    r0*: c4m_value_t
    r1*: c4m_value_t
    r2*: c4m_value_t
    r3*: c4m_value_t
    pc*: uint32
    num_frames*: int32
    running*: bool
    error*: bool

  c4m_vmthread_t* = struct_c4m_vmthread_t ## From libcon4m/include/core/dt_vm.h:579:3
  struct_c4m_callback_t* {.pure, inheritable, bycopy.} = object
    target_symbol_name*: ptr c4m_utf8_t ## From libcon4m/include/adts/dt_callbacks.h:4:9
    target_type*: ptr c4m_type_t
    decl_loc*: ptr c4m_tree_node_t
    binding*: c4m_funcinfo_t

  c4m_callback_t* = struct_c4m_callback_t
    ## From libcon4m/include/adts/dt_callbacks.h:9:3
  struct_c4m_control_info_t* {.pure, inheritable, bycopy.} = object
    label*: ptr c4m_utf8_t ## From libcon4m/include/compiler/dt_nodeinfo.h:14:9
    awaiting_patches*: ptr c4m_list_t
    entry_ip*: cint
    exit_ip*: cint
    non_loop*: bool

  c4m_control_info_t* = struct_c4m_control_info_t
    ## From libcon4m/include/compiler/dt_nodeinfo.h:20:3
  struct_c4m_loop_info_t* {.pure, inheritable, bycopy.} = object
    branch_info*: c4m_control_info_t ## From libcon4m/include/compiler/dt_nodeinfo.h:22:9
    label_ix*: ptr c4m_utf8_t
    label_last*: ptr c4m_utf8_t
    prelude*: ptr c4m_tree_node_t
    test*: ptr c4m_tree_node_t
    body*: ptr c4m_tree_node_t
    shadowed_ix*: ptr c4m_symbol_t
    loop_ix*: ptr c4m_symbol_t
    named_loop_ix*: ptr c4m_symbol_t
    shadowed_last*: ptr c4m_symbol_t
    loop_last*: ptr c4m_symbol_t
    named_loop_last*: ptr c4m_symbol_t
    lvar_1*: ptr c4m_symbol_t
    lvar_2*: ptr c4m_symbol_t
    shadowed_lvar_1*: ptr c4m_symbol_t
    shadowed_lvar_2*: ptr c4m_symbol_t
    ranged*: bool
    gen_ix* {.bitsize: 1.}: cuint
    gen_named_ix* {.bitsize: 1.}: cuint

  c4m_loop_info_t* = struct_c4m_loop_info_t
    ## From libcon4m/include/compiler/dt_nodeinfo.h:46:3
  struct_c4m_jump_info_t* {.pure, inheritable, bycopy.} = object
    linked_control_structure*: ptr c4m_control_info_t
      ## From libcon4m/include/compiler/dt_nodeinfo.h:48:16
    to_patch*: ptr c4m_zinstruction_t
    top*: bool

  c4m_jump_info_t* = struct_c4m_jump_info_t
    ## From libcon4m/include/compiler/dt_nodeinfo.h:52:3
  struct_c4m_spec_field_t_tinfo_t* {.union, bycopy.} = object
    type_field*: ptr c4m_type_t
    type_pointer*: ptr c4m_utf8_t

  struct_c4m_spec_field_t* {.pure, inheritable, bycopy.} = object
    tinfo*: struct_c4m_spec_field_t_tinfo_t
      ## From libcon4m/include/compiler/dt_specs.h:4:9
    stashed_options*: pointer
    declaration_node*: ptr c4m_tree_node_t
    name*: ptr c4m_utf8_t
    short_doc*: ptr c4m_utf8_t
    long_doc*: ptr c4m_utf8_t
    deferred_type_field*: ptr c4m_utf8_t
    default_value*: pointer
    validator*: pointer
    exclusions*: ptr c4m_set_t
    user_def_ok* {.bitsize: 1.}: cuint
    hidden* {.bitsize: 1.}: cuint
    required* {.bitsize: 1.}: cuint
    lock_on_write* {.bitsize: 1.}: cuint
    default_provided* {.bitsize: 1.}: cuint
    validate_range* {.bitsize: 1.}: cuint
    validate_choice* {.bitsize: 1.}: cuint
    have_type_pointer* {.bitsize: 1.}: cuint

  c4m_spec_field_t* = struct_c4m_spec_field_t
    ## From libcon4m/include/compiler/dt_specs.h:37:3
  struct_c4m_spec_section_t* {.pure, inheritable, bycopy.} = object
    declaration_node*: ptr c4m_tree_node_t
      ## From libcon4m/include/compiler/dt_specs.h:39:9
    name*: ptr c4m_utf8_t
    short_doc*: ptr c4m_utf8_t
    long_doc*: ptr c4m_utf8_t
    fields*: ptr c4m_dict_t
    allowed_sections*: ptr c4m_set_t
    required_sections*: ptr c4m_set_t
    validator*: pointer
    singleton* {.bitsize: 1.}: cuint
    user_def_ok* {.bitsize: 1.}: cuint
    hidden* {.bitsize: 1.}: cuint
    cycle* {.bitsize: 1.}: cuint

  c4m_spec_section_t* = struct_c4m_spec_section_t
    ## From libcon4m/include/compiler/dt_specs.h:52:3
  struct_c4m_spec_t* {.pure, inheritable, bycopy.} = object
    declaration_node*: ptr c4m_tree_node_t
      ## From libcon4m/include/compiler/dt_specs.h:54:9
    short_doc*: ptr c4m_utf8_t
    long_doc*: ptr c4m_utf8_t
    root_section*: ptr c4m_spec_section_t
    section_specs*: ptr c4m_dict_t
    locked* {.bitsize: 1.}: cuint

  c4m_spec_t* = struct_c4m_spec_t ## From libcon4m/include/compiler/dt_specs.h:61:3
  c4m_attr_status_t* = enum_c4m_attr_status_t
    ## From libcon4m/include/compiler/dt_specs.h:70:3
  c4m_attr_error_t* = enum_c4m_attr_error_t
    ## From libcon4m/include/compiler/dt_specs.h:78:3
  struct_c4m_attr_info_t_info_t* {.union, bycopy.} = object
    sec_info*: ptr c4m_spec_section_t
    field_info*: ptr c4m_spec_field_t

  struct_c4m_attr_info_t* {.pure, inheritable, bycopy.} = object
    err_arg*: ptr c4m_utf8_t ## From libcon4m/include/compiler/dt_specs.h:80:9
    info*: struct_c4m_attr_info_t_info_t
    err*: c4m_attr_error_t
    kind*: c4m_attr_status_t

  c4m_attr_info_t* = struct_c4m_attr_info_t
    ## From libcon4m/include/compiler/dt_specs.h:88:3
  c4m_cfg_node_t* = struct_c4m_cfg_node_t
    ## From libcon4m/include/compiler/dt_cfgs.h:4:31
  c4m_cfg_node_type* = enum_c4m_cfg_node_type
    ## From libcon4m/include/compiler/dt_cfgs.h:14:3
  struct_c4m_cfg_block_enter_info_t* {.pure, inheritable, bycopy.} = object
    next_node*: ptr c4m_cfg_node_t ## From libcon4m/include/compiler/dt_cfgs.h:16:9
    exit_node*: ptr c4m_cfg_node_t
    inbound_links*: ptr c4m_list_t
    to_merge*: ptr c4m_list_t

  c4m_cfg_block_enter_info_t* = struct_c4m_cfg_block_enter_info_t
    ## From libcon4m/include/compiler/dt_cfgs.h:21:3
  struct_c4m_cfg_block_exit_info_t* {.pure, inheritable, bycopy.} = object
    next_node*: ptr c4m_cfg_node_t ## From libcon4m/include/compiler/dt_cfgs.h:23:9
    entry_node*: ptr c4m_cfg_node_t
    inbound_links*: ptr c4m_list_t
    to_merge*: ptr c4m_list_t

  c4m_cfg_block_exit_info_t* = struct_c4m_cfg_block_exit_info_t
    ## From libcon4m/include/compiler/dt_cfgs.h:28:3
  struct_c4m_cfg_jump_info_t* {.pure, inheritable, bycopy.} = object
    dead_code*: ptr c4m_cfg_node_t ## From libcon4m/include/compiler/dt_cfgs.h:30:9
    target*: ptr c4m_cfg_node_t

  c4m_cfg_jump_info_t* = struct_c4m_cfg_jump_info_t
    ## From libcon4m/include/compiler/dt_cfgs.h:33:3
  struct_c4m_cfg_branch_info_t* {.pure, inheritable, bycopy.} = object
    exit_node*: ptr c4m_cfg_node_t ## From libcon4m/include/compiler/dt_cfgs.h:35:9
    branch_targets*: ptr ptr c4m_cfg_node_t
    label*: ptr c4m_utf8_t
    num_branches*: int64
    next_to_process*: int64

  c4m_cfg_branch_info_t* = struct_c4m_cfg_branch_info_t
    ## From libcon4m/include/compiler/dt_cfgs.h:41:3
  struct_c4m_cfg_flow_info_t* {.pure, inheritable, bycopy.} = object
    next_node*: ptr c4m_cfg_node_t ## From libcon4m/include/compiler/dt_cfgs.h:43:9
    dst_symbol*: ptr c4m_symbol_t
    deps*: ptr c4m_list_t

  c4m_cfg_flow_info_t* = struct_c4m_cfg_flow_info_t
    ## From libcon4m/include/compiler/dt_cfgs.h:47:3
  struct_c4m_cfg_status_t* {.pure, inheritable, bycopy.} = object
    last_def*: ptr c4m_cfg_node_t ## From libcon4m/include/compiler/dt_cfgs.h:49:9
    last_use*: ptr c4m_cfg_node_t

  c4m_cfg_status_t* = struct_c4m_cfg_status_t
    ## From libcon4m/include/compiler/dt_cfgs.h:52:3
  c4m_module_compile_status* = enum_c4m_module_compile_status
    ## From libcon4m/include/compiler/dt_module.h:13:3
  c4m_module_compile_ctx* = struct_c4m_module_compile_ctx
    ## From libcon4m/include/compiler/dt_module.h:62:3
  struct_c4m_compile_ctx* {.pure, inheritable, bycopy.} = object
    final_attrs*: ptr c4m_scope_t ## From libcon4m/include/compiler/dt_compile.h:4:9
    final_globals*: ptr c4m_scope_t
    final_spec*: ptr c4m_spec_t
    entry_point*: ptr c4m_module_compile_ctx
    sys_package*: ptr c4m_module_compile_ctx
    module_cache*: ptr c4m_dict_t
    module_ordering*: ptr c4m_list_t
    backlog*: ptr c4m_set_t
    processed*: ptr c4m_set_t
    const_data*: ptr c4m_buf_t
    const_instantiations*: ptr c4m_buf_t
    const_memos*: ptr c4m_dict_t
    const_instance_map*: ptr c4m_dict_t
    const_stream*: ptr c4m_stream_t
    instance_map*: ptr c4m_dict_t
    str_map*: ptr c4m_dict_t
    const_memoid*: int64
    const_instantiation_id*: int32
    fatality*: bool

  c4m_compile_ctx* = struct_c4m_compile_ctx
    ## From libcon4m/include/compiler/dt_compile.h:32:3
  c4m_size_t* = uint64 ## From libcon4m/include/con4m/datatypes.h:42:25
  c4m_duration_t* = struct_timespec ## From libcon4m/include/con4m/datatypes.h:43:25
  struct_timespec* {.pure, inheritable, bycopy.} = object
    tv_sec*: compiler_time_t ## From /usr/include/bits/types/struct_timespec.h:11:8
    tv_nsec*: compiler_syscall_slong_t

  c4m_repr_fn* = proc(a0: c4m_obj_t): ptr c4m_str_t {.cdecl.}
    ## From libcon4m/include/con4m/datatypes.h:45:22
  c4m_marshal_fn* = proc(
    a0: c4m_obj_t, a1: ptr c4m_stream_t, a2: ptr c4m_dict_t, a3: ptr int64
  ): void {.cdecl.} ## From libcon4m/include/con4m/datatypes.h:46:16
  c4m_unmarshal_fn* =
    proc(a0: c4m_obj_t, a1: ptr c4m_stream_t, a2: ptr c4m_dict_t): void {.cdecl.}
    ## From libcon4m/include/con4m/datatypes.h:50:16
  c4m_copy_fn* = proc(a0: c4m_obj_t): c4m_obj_t {.cdecl.}
    ## From libcon4m/include/con4m/datatypes.h:51:21
  c4m_binop_fn* = proc(a0: c4m_obj_t, a1: c4m_obj_t): c4m_obj_t {.cdecl.}
    ## From libcon4m/include/con4m/datatypes.h:52:21
  c4m_len_fn* = proc(a0: c4m_obj_t): int64 {.cdecl.}
    ## From libcon4m/include/con4m/datatypes.h:53:19
  c4m_index_get_fn* = proc(a0: c4m_obj_t, a1: c4m_obj_t): c4m_obj_t {.cdecl.}
    ## From libcon4m/include/con4m/datatypes.h:54:21
  c4m_index_set_fn* = proc(a0: c4m_obj_t, a1: c4m_obj_t, a2: c4m_obj_t): void {.cdecl.}
    ## From libcon4m/include/con4m/datatypes.h:55:16
  c4m_slice_get_fn* = proc(a0: c4m_obj_t, a1: int64, a2: int64): c4m_obj_t {.cdecl.}
    ## From libcon4m/include/con4m/datatypes.h:56:21
  c4m_slice_set_fn* =
    proc(a0: c4m_obj_t, a1: int64, a2: int64, a3: c4m_obj_t): void {.cdecl.}
    ## From libcon4m/include/con4m/datatypes.h:57:16
  c4m_can_coerce_fn* = proc(a0: ptr c4m_type_t, a1: ptr c4m_type_t): bool {.cdecl.}
    ## From libcon4m/include/con4m/datatypes.h:58:16
  c4m_coerce_fn* = proc(a0: pointer, a1: ptr c4m_type_t): pointer {.cdecl.}
    ## From libcon4m/include/con4m/datatypes.h:59:17
  c4m_cmp_fn* = proc(a0: c4m_obj_t, a1: c4m_obj_t): bool {.cdecl.}
    ## From libcon4m/include/con4m/datatypes.h:60:16
  c4m_literal_fn* = proc(
    a0: ptr c4m_utf8_t,
    a1: c4m_lit_syntax_t,
    a2: ptr c4m_utf8_t,
    a3: ptr c4m_compile_error_t,
  ): c4m_obj_t {.cdecl.} ## From libcon4m/include/con4m/datatypes.h:61:21
  c4m_container_lit_fn* = proc(
    a0: ptr c4m_type_t, a1: ptr c4m_list_t, a2: ptr c4m_utf8_t
  ): c4m_obj_t {.cdecl.} ## From libcon4m/include/con4m/datatypes.h:65:21
  c4m_format_fn* = proc(a0: c4m_obj_t, a1: ptr c4m_fmt_spec_t): ptr c4m_str_t {.cdecl.}
    ## From libcon4m/include/con4m/datatypes.h:68:22
  c4m_ix_item_ty_fn* = proc(a0: ptr c4m_type_t): ptr c4m_type_t {.cdecl.}
    ## From libcon4m/include/con4m/datatypes.h:69:23
  c4m_view_fn* = proc(a0: c4m_obj_t, a1: ptr uint64): pointer {.cdecl.}
    ## From libcon4m/include/con4m/datatypes.h:70:17
  va_list* = compiler_builtin_va_list
    ## From /usr/lib/clang/18/include/__stdarg_va_list.h:12:27
  struct_refcount_alloc_t* {.pure, inheritable, bycopy.} = object
    refcount*: Atomic[int64] ## From libcon4m/include/core/refcount.h:18:9
    data*: ptr UncheckedArray[cschar]

  refcount_alloc_t* = struct_refcount_alloc_t
    ## From libcon4m/include/core/refcount.h:21:3
  cleanup_fn* = proc(a0: pointer): void {.cdecl.}
    ## From libcon4m/include/core/refcount.h:54:16
  c4m_gc_hook* = proc(): void {.cdecl.} ## From libcon4m/include/core/gc.h:233:16
  ptrdiff_t* = clong ## From /usr/lib/clang/18/include/__stddef_ptrdiff_t.h:18:26
  c4m_sort_fn* = proc(a0: pointer, a1: pointer): cint {.cdecl.}
    ## From libcon4m/include/adts/list.h:5:15
  c4m_file_kind* = enum_c4m_file_kind ## From libcon4m/include/util/path.h:15:3
  struct_c4m_ipaddr_t* {.pure, inheritable, bycopy.} = object
    addr_field*: array[28, cschar] ## From libcon4m/include/adts/ipaddr.h:5:9
    port*: uint16
    af*: int32

  c4m_ipaddr_t* = struct_c4m_ipaddr_t ## From libcon4m/include/adts/ipaddr.h:9:3
  struct_c4m_date_time_t* {.pure, inheritable, bycopy.} = object
    dt*: struct_tm ## From libcon4m/include/adts/datetime.h:4:16
    fracsec*: int64
    have_time* {.bitsize: 1.}: cuint
    have_sec* {.bitsize: 1.}: cuint
    have_frac_sec* {.bitsize: 1.}: cuint
    have_month* {.bitsize: 1.}: cuint
    have_year* {.bitsize: 1.}: cuint
    have_day* {.bitsize: 1.}: cuint
    have_offset* {.bitsize: 1.}: cuint

  struct_tm* {.pure, inheritable, bycopy.} = object
    tm_sec*: cint ## From /usr/include/bits/types/struct_tm.h:7:8
    tm_min*: cint
    tm_hour*: cint
    tm_mday*: cint
    tm_mon*: cint
    tm_year*: cint
    tm_wday*: cint
    tm_yday*: cint
    tm_isdst*: cint
    tm_gmtoff*: clong
    tm_zone*: cstring

  c4m_date_time_t* = struct_c4m_date_time_t ## From libcon4m/include/adts/datetime.h:14:3
  c4m_http_method_t* = enum_c4m_http_method_t ## From libcon4m/include/io/http.h:9:3
  struct_c4m_basic_http_t* {.pure, inheritable, bycopy.} = object
    curl*: pointer ## From libcon4m/include/io/http.h:11:9
    buf*: ptr c4m_buf_t
    to_send*: ptr c4m_stream_t
    output_stream*: ptr c4m_stream_t
    errbuf*: cstring
    lock*: pthread_mutex_t
    code*: CURLcode

  pthread_mutex_t* = union_pthread_mutex_t ## From /usr/include/bits/pthreadtypes.h:72:3
  CURLcode* = enum_CURLcode ## From /usr/include/curl/curl.h:645:3
  c4m_basic_http_t* = struct_c4m_basic_http_t ## From libcon4m/include/io/http.h:20:3
  struct_c4m_basic_http_response_t* {.pure, inheritable, bycopy.} = object
    contents*: ptr c4m_buf_t ## From libcon4m/include/io/http.h:22:9
    error*: ptr c4m_utf8_t
    code*: CURLcode

  c4m_basic_http_response_t* = struct_c4m_basic_http_response_t
    ## From libcon4m/include/io/http.h:26:3
  CURLoption* = enum_CURLoption ## From /usr/include/curl/curl.h:2228:3
  compiler_pid_t* = cint ## From /usr/include/bits/types.h:154:25
  tcflag_t* = cuint ## From /usr/include/bits/termios.h:25:22
  cc_t* = uint8 ## From /usr/include/bits/termios.h:23:23
  speed_t* = cuint ## From /usr/include/bits/termios.h:24:22
  compiler_ssize_t* = clong ## From /usr/include/bits/types.h:194:27
  struct_IO_FILE* {.pure, inheritable, bycopy.} = object
    internal_flags*: cint ## From /usr/include/bits/types/struct_FILE.h:49:8
    internal_IO_read_ptr*: cstring
    internal_IO_read_end*: cstring
    internal_IO_read_base*: cstring
    internal_IO_write_base*: cstring
    internal_IO_write_ptr*: cstring
    internal_IO_write_end*: cstring
    internal_IO_buf_base*: cstring
    internal_IO_buf_end*: cstring
    internal_IO_save_base*: cstring
    internal_IO_backup_base*: cstring
    internal_IO_save_end*: cstring
    internal_markers*: ptr struct_IO_marker
    internal_chain*: ptr struct_IO_FILE
    internal_fileno*: cint
    internal_flags2*: cint
    internal_old_offset*: compiler_off_t
    internal_cur_column*: cushort
    internal_vtable_offset*: cschar
    internal_shortbuf*: array[1, cschar]
    internal_lock*: pointer
    internal_offset*: compiler_off64_t
    internal_codecvt*: ptr struct_IO_codecvt
    internal_wide_data*: ptr struct_IO_wide_data
    internal_freeres_list*: ptr struct_IO_FILE
    internal_freeres_buf*: pointer
    internal_prevchain*: ptr ptr struct_IO_FILE
    internal_mode*: cint
    internal_unused2*: array[20, cschar]

  union_pthread_rwlock_t* {.union, bycopy.} = object
    compiler_data*: struct_pthread_rwlock_arch_t
      ## From /usr/include/bits/pthreadtypes.h:86:9
    compiler_size*: array[56, cschar]
    compiler_align*: clong

  sa_family_t* = cushort ## From /usr/include/bits/sockaddr.h:28:28
  compiler_socklen_t* = cuint ## From /usr/include/bits/types.h:210:23
  compiler_time_t* = clong ## From /usr/include/bits/types.h:160:26
  compiler_suseconds_t* = clong ## From /usr/include/bits/types.h:162:31
  struct_fd_set* {.pure, inheritable, bycopy.} = object
    compiler_fds_bits*: array[16, compiler_fd_mask]
      ## From /usr/include/sys/select.h:59:9

  struct_jmp_buf_tag* {.pure, inheritable, bycopy.} = object
    compiler_jmpbuf*: compiler_jmp_buf
      ## From /usr/include/bits/types/struct___jmp_buf_tag.h:26:8
    compiler_mask_was_saved*: cint
    compiler_saved_mask*: compiler_sigset_t

  compiler_syscall_slong_t* = clong ## From /usr/include/bits/types.h:197:33
  union_pthread_mutex_t* {.union, bycopy.} = object
    compiler_data*: struct_pthread_mutex_s ## From /usr/include/bits/pthreadtypes.h:67:9
    compiler_size*: array[40, cschar]
    compiler_align*: clong

  compiler_off_t* = clong ## From /usr/include/bits/types.h:152:25
  compiler_off64_t* = clong ## From /usr/include/bits/types.h:153:27
  struct_pthread_rwlock_arch_t* {.pure, inheritable, bycopy.} = object
    compiler_readers*: cuint ## From /usr/include/bits/struct_rwlock.h:23:8
    compiler_writers*: cuint
    compiler_wrphase_futex*: cuint
    compiler_writers_futex*: cuint
    compiler_pad3*: cuint
    compiler_pad4*: cuint
    compiler_cur_writer*: cint
    compiler_shared*: cint
    compiler_rwelision*: cschar
    compiler_pad1*: array[7, uint8]
    compiler_pad2*: culong
    compiler_flags*: cuint

  compiler_fd_mask* = clong ## From /usr/include/sys/select.h:49:18
  compiler_jmp_buf* = array[8, clong] ## From /usr/include/bits/setjmp.h:31:18
  compiler_sigset_t* = struct_sigset_t ## From /usr/include/bits/types/__sigset_t.h:8:3
  struct_pthread_mutex_s* {.pure, inheritable, bycopy.} = object
    compiler_lock*: cint ## From /usr/include/bits/struct_mutex.h:22:8
    compiler_count*: cuint
    compiler_owner*: cint
    compiler_nusers*: cuint
    compiler_kind*: cint
    compiler_spins*: cshort
    compiler_elision*: cshort
    compiler_list*: compiler_pthread_list_t

  struct_sigset_t* {.pure, inheritable, bycopy.} = object
    compiler_val*: array[16, culong] ## From /usr/include/bits/types/__sigset_t.h:5:9

  compiler_pthread_list_t* = struct_pthread_internal_list
    ## From /usr/include/bits/thread-shared-types.h:55:3
  struct_pthread_internal_list* {.pure, inheritable, bycopy.} = object
    compiler_prev*: ptr struct_pthread_internal_list
      ## From /usr/include/bits/thread-shared-types.h:51:16
    compiler_next*: ptr struct_pthread_internal_list

const
  C4M_FORCED_ALIGNMENT* = 16 ## From libcon4m/include/con4m/config.h:17:9
  C4M_MIN_RENDER_WIDTH* = 80 ## From libcon4m/include/con4m/config.h:96:9
  C4M_MAX_KARGS_NESTING_DEPTH* = 32 ## From libcon4m/include/con4m/config.h:115:9
  C4M_MAX_KEYWORD_SIZE* = 32 ## From libcon4m/include/con4m/config.h:120:9
  C4M_EMPTY_BUFFER_ALLOC* = 128 ## From libcon4m/include/con4m/config.h:138:9
  C4M_MAX_CALL_DEPTH* = 100 ## From libcon4m/include/con4m/config.h:151:9
  C4M_GC_DEFAULT_ON* = 1 ## From libcon4m/include/con4m/config.h:165:9
  C4M_GC_DEFAULT_OFF* = 0 ## From libcon4m/include/con4m/config.h:166:9
  C4M_GCT_INIT* = C4M_GC_DEFAULT_ON ## From libcon4m/include/con4m/config.h:170:9
  C4M_GCT_MMAP* = C4M_GC_DEFAULT_ON ## From libcon4m/include/con4m/config.h:173:9
  C4M_GCT_MUNMAP* = C4M_GC_DEFAULT_ON ## From libcon4m/include/con4m/config.h:176:9
  C4M_GCT_SCAN* = C4M_GC_DEFAULT_ON ## From libcon4m/include/con4m/config.h:179:9
  C4M_GCT_OBJ* = C4M_GC_DEFAULT_OFF ## From libcon4m/include/con4m/config.h:182:9
  C4M_GCT_SCAN_PTR* = C4M_GC_DEFAULT_OFF ## From libcon4m/include/con4m/config.h:185:9
  C4M_GCT_PTR_TEST* = C4M_GC_DEFAULT_OFF ## From libcon4m/include/con4m/config.h:188:9
  C4M_GCT_PTR_TO_MOVE* = C4M_GC_DEFAULT_OFF ## From libcon4m/include/con4m/config.h:191:9
  C4M_GCT_MOVE* = C4M_GC_DEFAULT_OFF ## From libcon4m/include/con4m/config.h:194:9
  C4M_GCT_ALLOC_FOUND* = C4M_GC_DEFAULT_OFF ## From libcon4m/include/con4m/config.h:197:9
  C4M_GCT_PTR_THREAD* = C4M_GC_DEFAULT_OFF ## From libcon4m/include/con4m/config.h:200:9
  C4M_GCT_MOVED* = C4M_GC_DEFAULT_OFF ## From libcon4m/include/con4m/config.h:203:9
  C4M_GCT_COLLECT* = C4M_GC_DEFAULT_ON ## From libcon4m/include/con4m/config.h:206:9
  C4M_GCT_REGISTER* = C4M_GC_DEFAULT_ON ## From libcon4m/include/con4m/config.h:209:9
  C4M_GCT_ALLOC* = C4M_GC_DEFAULT_OFF ## From libcon4m/include/con4m/config.h:212:9
  C4M_TEST_SUITE_TIMEOUT_SEC* = 1 ## From libcon4m/include/con4m/config.h:219:9
  C4M_TEST_SUITE_TIMEOUT_USEC* = 0 ## From libcon4m/include/con4m/config.h:222:9
  C4M_PACKAGE_INIT_MODULE* = "__init" ## From libcon4m/include/con4m/config.h:228:9
  HATRACK_MIN_SIZE_LOG* = 4 ## From libcon4m/include/hatrack/hatrack_config.h:59:9
  HATRACK_THREADS_MAX* = 4096 ## From libcon4m/include/hatrack/hatrack_config.h:284:9
  HATRACK_RETIRE_FREQ_LOG* = 7 ## From libcon4m/include/hatrack/hatrack_config.h:317:9
  HIHATa_MIGRATE_SLEEP_TIME_NS* = 500000
    ## From libcon4m/include/hatrack/hatrack_config.h:339:9
  HATRACK_RETRY_THRESHOLD* = 7 ## From libcon4m/include/hatrack/hatrack_config.h:360:9
  HATRACK_QSORT_THRESHOLD* = 256 ## From libcon4m/include/hatrack/hatrack_config.h:473:9
  HATRACK_SEED_SIZE* = 32 ## From libcon4m/include/hatrack/hatrack_config.h:504:9
  HATRACK_RAND_SEED_SIZE* = 32 ## From libcon4m/include/hatrack/hatrack_config.h:548:9
  HATRACK_MAX_HATS* = 1024 ## From libcon4m/include/hatrack/hatrack_config.h:579:9
  QUEUE_HELP_STEPS* = 4 ## From libcon4m/include/hatrack/hatrack_config.h:623:9
  QSIZE_LOG_DEFAULT* = 14 ## From libcon4m/include/hatrack/hatrack_config.h:631:9
  QSIZE_LOG_MIN* = 6 ## From libcon4m/include/hatrack/hatrack_config.h:635:9
  QSIZE_LOG_MAX* = 25 ## From libcon4m/include/hatrack/hatrack_config.h:639:9
  HATSTACK_RETRY_THRESHOLD* = 7 ## From libcon4m/include/hatrack/hatrack_config.h:663:9
  HATSTACK_MAX_BACKOFF* = 4 ## From libcon4m/include/hatrack/hatrack_config.h:670:9
  HATSTACK_MIN_STORE_SZ_LOG* = 6 ## From libcon4m/include/hatrack/hatrack_config.h:677:9
  CAPQ_DEFAULT_SIZE* = 1024 ## From libcon4m/include/hatrack/hatrack_config.h:692:9
  CAPQ_MINIMUM_SIZE* = 256 ## From libcon4m/include/hatrack/hatrack_config.h:703:9
  CAPQ_TOP_SUSPEND_THRESHOLD* = 2 ## From libcon4m/include/hatrack/hatrack_config.h:725:9
  FLEXARRAY_DEFAULT_GROW_SIZE_LOG* = 8
    ## From libcon4m/include/hatrack/hatrack_config.h:728:9

type HATRACK_EXTERN* = extern ## From libcon4m/include/hatrack/base.h:37:9

const
  XXHASH_H_5627135585666179* = 1 ## From libcon4m/include/hatrack/xxhash.h:225:9
  XXH_VERSION_MAJOR* = 0 ## From libcon4m/include/hatrack/xxhash.h:331:9
  XXH_VERSION_MINOR* = 8 ## From libcon4m/include/hatrack/xxhash.h:332:9
  XXH_VERSION_RELEASE* = 1 ## From libcon4m/include/hatrack/xxhash.h:333:9
  XXH3_SECRET_SIZE_MIN* = 136 ## From libcon4m/include/hatrack/xxhash.h:841:9
  XXH3_INTERNALBUFFER_SIZE* = 256 ## From libcon4m/include/hatrack/xxhash.h:1107:9
  XXH3_SECRET_DEFAULT_SIZE* = 192 ## From libcon4m/include/hatrack/xxhash.h:1116:9
  XXH_ACCEPT_NULL_INPUT_POINTER* = 0 ## From libcon4m/include/hatrack/xxhash.h:1449:9
  XXH_FORCE_ALIGN_CHECK* = 0 ## From libcon4m/include/hatrack/xxhash.h:1455:9
  XXH_NO_INLINE_HINTS* = 1 ## From libcon4m/include/hatrack/xxhash.h:1464:9
  XXH_REROLL* = 0 ## From libcon4m/include/hatrack/xxhash.h:1476:9
  XXH_DEBUGLEVEL* = 0 ## From libcon4m/include/hatrack/xxhash.h:1575:9
  XXH_CPU_LITTLE_ENDIAN* = 1 ## From libcon4m/include/hatrack/xxhash.h:1785:9
  XXH_PRIME32_1* = cuint(2654435761) ## From libcon4m/include/hatrack/xxhash.h:1956:9
  XXH_PRIME32_2* = cuint(2246822519) ## From libcon4m/include/hatrack/xxhash.h:1957:9
  XXH_PRIME32_3* = cuint(3266489917) ## From libcon4m/include/hatrack/xxhash.h:1958:9
  XXH_PRIME32_4* = cuint(668265263) ## From libcon4m/include/hatrack/xxhash.h:1959:9
  XXH_PRIME32_5* = cuint(374761393) ## From libcon4m/include/hatrack/xxhash.h:1960:9

type XXH_RESTRICT* = restrict ## From libcon4m/include/hatrack/xxhash.h:2912:9

const
  XXH_SCALAR* = 0 ## From libcon4m/include/hatrack/xxhash.h:3070:9
  XXH_SSE2* = 1 ## From libcon4m/include/hatrack/xxhash.h:3071:9
  XXH_AVX2* = 2 ## From libcon4m/include/hatrack/xxhash.h:3072:9
  XXH_AVX512* = 3 ## From libcon4m/include/hatrack/xxhash.h:3073:9
  XXH_NEON* = 4 ## From libcon4m/include/hatrack/xxhash.h:3074:9
  XXH_VSX* = 5 ## From libcon4m/include/hatrack/xxhash.h:3075:9
  XXH_VECTOR* = XXH_SSE2 ## From libcon4m/include/hatrack/xxhash.h:3085:9
  XXH_ACC_ALIGN* = 16 ## From libcon4m/include/hatrack/xxhash.h:3111:9
  XXH_SEC_ALIGN* = XXH_ACC_ALIGN ## From libcon4m/include/hatrack/xxhash.h:3125:9
  XXH_SECRET_DEFAULT_SIZE* = 192 ## From libcon4m/include/hatrack/xxhash.h:3413:9
  XXH3_MIDSIZE_MAX* = 240 ## From libcon4m/include/hatrack/xxhash.h:4061:9
  XXH3_MIDSIZE_STARTOFFSET* = 3 ## From libcon4m/include/hatrack/xxhash.h:4074:9
  XXH3_MIDSIZE_LASTOFFSET* = 17 ## From libcon4m/include/hatrack/xxhash.h:4075:9
  XXH_STRIPE_LEN* = 64 ## From libcon4m/include/hatrack/xxhash.h:4128:9

{.pragma: lc4m, cdecl, importc.}

proc XXH3_accumulate_512_sse2*(
  acc: pointer, input: pointer, secret: pointer
): void {.lc4m.}

proc XXH3_scrambleAcc_sse2*(acc: pointer, secret: pointer): void {.lc4m.}

proc XXH3_initCustomSecret_sse2*(customSecret: pointer, seed64: xxh_u64): void {.lc4m.}

const
  XXH_PREFETCH_DIST* = 320 ## From libcon4m/include/hatrack/xxhash.h:4880:9
  XXH_SECRET_MERGEACCS_START* = 11 ## From libcon4m/include/hatrack/xxhash.h:5028:9
  C4M_T_XLIST* = C4M_T_LIST ## From libcon4m/include/core/dt_objects.h:193:9
  C4M_BORDER_TOP* = 1 ## From libcon4m/include/util/dt_styles.h:17:9
  C4M_BORDER_BOTTOM* = 2 ## From libcon4m/include/util/dt_styles.h:18:9
  C4M_BORDER_LEFT* = 4 ## From libcon4m/include/util/dt_styles.h:19:9
  C4M_BORDER_RIGHT* = 8 ## From libcon4m/include/util/dt_styles.h:20:9
  C4M_INTERIOR_HORIZONTAL* = 16 ## From libcon4m/include/util/dt_styles.h:21:9
  C4M_INTERIOR_VERTICAL* = 32 ## From libcon4m/include/util/dt_styles.h:22:9
  C4M_STR_HASH_KEY_POINTER_OFFSET* = 0 ## From libcon4m/include/adts/dt_strings.h:10:9
  C4M_FN_TY_VARARGS* = 1 ## From libcon4m/include/core/dt_types.h:29:9
  C4M_FN_TY_LOCK* = 2 ## From libcon4m/include/core/dt_types.h:37:9
  C4M_FN_UNKNOWN_TV_LEN* = 4 ## From libcon4m/include/core/dt_types.h:47:9
  C4M_IO_HEAP_SZ* = 256 ## From libcon4m/include/io/dt_io.h:5:9
  PIPE_BUF* = 4096 ## From /usr/include/linux/limits.h:14:9
  C4M_SP_IO_STDIN* = 1 ## From libcon4m/include/io/dt_io.h:278:9
  C4M_SP_IO_STDOUT* = 2 ## From libcon4m/include/io/dt_io.h:279:9
  C4M_SP_IO_STDERR* = 4 ## From libcon4m/include/io/dt_io.h:280:9
  C4M_SP_IO_ALL* = 7 ## From libcon4m/include/io/dt_io.h:281:9
  C4M_CAP_ALLOC* = 16 ## From libcon4m/include/io/dt_io.h:282:9
  C4M_F_STREAM_READ* = 1 ## From libcon4m/include/adts/dt_streams.h:34:9
  C4M_F_STREAM_WRITE* = 2 ## From libcon4m/include/adts/dt_streams.h:35:9
  C4M_F_STREAM_APPEND* = 4 ## From libcon4m/include/adts/dt_streams.h:36:9
  C4M_F_STREAM_CLOSED* = 8 ## From libcon4m/include/adts/dt_streams.h:37:9
  C4M_F_STREAM_BUFFER_IN* = 16 ## From libcon4m/include/adts/dt_streams.h:38:9
  C4M_F_STREAM_STR_IN* = 32 ## From libcon4m/include/adts/dt_streams.h:39:9
  C4M_F_STREAM_UTF8_OUT* = 64 ## From libcon4m/include/adts/dt_streams.h:40:9
  C4M_F_STREAM_UTF32_OUT* = 128 ## From libcon4m/include/adts/dt_streams.h:41:9
  C4M_F_STREAM_USING_COOKIE* = 256 ## From libcon4m/include/adts/dt_streams.h:42:9
  C4M_FMT_FMT_ONLY* = 0 ## From libcon4m/include/util/dt_format.h:27:9
  C4M_FMT_NUMBERED* = 1 ## From libcon4m/include/util/dt_format.h:28:9
  C4M_FMT_NAMED* = 2 ## From libcon4m/include/util/dt_format.h:29:9
  C4M_FMT_ALIGN_LEFT* = 0 ## From libcon4m/include/util/dt_format.h:32:9
  C4M_FMT_ALIGN_RIGHT* = 1 ## From libcon4m/include/util/dt_format.h:33:9
  C4M_FMT_ALIGN_CENTER* = 2 ## From libcon4m/include/util/dt_format.h:34:9
  C4M_FMT_SIGN_DEFAULT* = 0 ## From libcon4m/include/util/dt_format.h:37:9
  C4M_FMT_SIGN_ALWAYS* = 1 ## From libcon4m/include/util/dt_format.h:38:9
  C4M_FMT_SIGN_POS_SPACE* = 2 ## From libcon4m/include/util/dt_format.h:39:9
  C4M_FMT_SEP_DEFAULT* = 0 ## From libcon4m/include/util/dt_format.h:43:9
  C4M_FMT_SEP_COMMA* = 1 ## From libcon4m/include/util/dt_format.h:44:9
  C4M_FMT_SEP_USCORE* = 2 ## From libcon4m/include/util/dt_format.h:45:9

const c4m_err_no_error* = c4m_err_last
  ## From libcon4m/include/compiler/dt_errors.h:200:9

var
  ffi_type_uint8* {.importc.}: c4m_ffi_type
  ffi_type_sint8* {.importc.}: c4m_ffi_type
  ffi_type_uint16* {.importc.}: c4m_ffi_type
  ffi_type_sint16* {.importc.}: c4m_ffi_type
  ffi_type_uint32* {.importc.}: c4m_ffi_type
  ffi_type_sint32* {.importc.}: c4m_ffi_type
  ffi_type_uint64* {.importc.}: c4m_ffi_type
  ffi_type_sint64* {.importc.}: c4m_ffi_type

const
  C4M_F_ATTR_PUSH_FOUND* = 1 ## From libcon4m/include/core/dt_vm.h:581:9
  C4M_F_ATTR_SKIP_LOAD* = 2 ## From libcon4m/include/core/dt_vm.h:582:9
  C4M_CB_FLAG_FFI* = 1 ## From libcon4m/include/adts/dt_callbacks.h:11:9
  C4M_CB_FLAG_STATIC* = 2 ## From libcon4m/include/adts/dt_callbacks.h:12:9
  GC_FLAG_COLLECTING* = 1 ## From libcon4m/include/core/gc.h:71:9
  GC_FLAG_REACHED* = 2 ## From libcon4m/include/core/gc.h:74:9
  GC_FLAG_MOVED* = 4 ## From libcon4m/include/core/gc.h:78:9
  GC_FLAG_WRITER_LOCK* = 8 ## From libcon4m/include/core/gc.h:81:9
  GC_FLAG_OWNER_WAITING* = 16 ## From libcon4m/include/core/gc.h:84:9
  GC_FLAG_GLOBAL_STOP* = 32 ## From libcon4m/include/core/gc.h:87:9
  C4M_HEADER_SCAN_CONST* = cast[culonglong](2'i64)
    ## From libcon4m/include/core/object.h:33:9
  C4M_STY_FG* = cast[culong](562949953421312'i64)
    ## From libcon4m/include/util/style.h:6:9
  C4M_STY_BG* = cast[culong](1125899906842624'i64)
    ## From libcon4m/include/util/style.h:7:9
  C4M_STY_BOLD* = cast[culong](2251799813685248'i64)
    ## From libcon4m/include/util/style.h:8:9
  C4M_STY_ITALIC* = cast[culong](4503599627370496'i64)
    ## From libcon4m/include/util/style.h:9:9
  C4M_STY_ST* = cast[culong](9007199254740992'i64)
    ## From libcon4m/include/util/style.h:10:9
  C4M_STY_UL* = cast[culong](18014398509481984'i64)
    ## From libcon4m/include/util/style.h:11:9
  C4M_STY_UUL* = cast[culong](36028797018963968'i64)
    ## From libcon4m/include/util/style.h:12:9
  C4M_STY_REV* = cast[culong](72057594037927936'i64)
    ## From libcon4m/include/util/style.h:13:9
  C4M_STY_LOWER* = cast[culong](144115188075855872'i64)
    ## From libcon4m/include/util/style.h:14:9
  C4M_STY_UPPER* = cast[culong](288230376151711744'i64)
    ## From libcon4m/include/util/style.h:15:9
  C4M_STY_BAD* = cast[culong](-1'i64) ## From libcon4m/include/util/style.h:17:9
  C4M_STY_CLEAR_FG* = cast[culong](-16777216'i64)
    ## From libcon4m/include/util/style.h:18:9
  C4M_STY_CLEAR_BG* = cast[culong](-281474959933441'i64)
    ## From libcon4m/include/util/style.h:19:9
  C4M_STY_CLEAR_FLAGS* = cast[culong](281474976710655'i64)
    ## From libcon4m/include/util/style.h:20:9
  C4M_OFFSET_BG_RED* = 40 ## From libcon4m/include/util/style.h:22:9
  C4M_OFFSET_BG_GREEN* = 32 ## From libcon4m/include/util/style.h:23:9
  C4M_OFFSET_BG_BLUE* = 24 ## From libcon4m/include/util/style.h:24:9
  C4M_OFFSET_FG_RED* = 16 ## From libcon4m/include/util/style.h:25:9
  C4M_OFFSET_FG_GREEN* = 8 ## From libcon4m/include/util/style.h:26:9
  C4M_OFFSET_FG_BLUE* = 0 ## From libcon4m/include/util/style.h:27:9
  C4M_INDEX_FN* = "$index" ## From libcon4m/include/compiler/module.h:59:9
  C4M_SLICE_FN* = "$slice" ## From libcon4m/include/compiler/module.h:60:9
  C4M_PLUS_FN* = "$plus" ## From libcon4m/include/compiler/module.h:61:9
  C4M_MINUS_FN* = "$minus" ## From libcon4m/include/compiler/module.h:62:9
  C4M_MUL_FN* = "$mul" ## From libcon4m/include/compiler/module.h:63:9
  C4M_MOD_FN* = "$mod" ## From libcon4m/include/compiler/module.h:64:9
  C4M_DIV_FN* = "$div" ## From libcon4m/include/compiler/module.h:65:9
  C4M_FDIV_FN* = "$fdiv" ## From libcon4m/include/compiler/module.h:66:9
  C4M_SHL_FN* = "$shl" ## From libcon4m/include/compiler/module.h:67:9
  C4M_SHR_FN* = "$shr" ## From libcon4m/include/compiler/module.h:68:9
  C4M_BAND_FN* = "$bit_and" ## From libcon4m/include/compiler/module.h:69:9
  C4M_BOR_FN* = "$bit_or" ## From libcon4m/include/compiler/module.h:70:9
  C4M_BXOR_FN* = "$bit_xor" ## From libcon4m/include/compiler/module.h:71:9
  C4M_CMP_FN* = "$cmp" ## From libcon4m/include/compiler/module.h:72:9
  C4M_SET_INDEX* = "$set_index" ## From libcon4m/include/compiler/module.h:73:9
  C4M_SET_SLICE* = "$set_slice" ## From libcon4m/include/compiler/module.h:74:9

proc hatrack_set_contains*(a0: ptr hatrack_set_t, a1: pointer): bool {.lc4m.}

proc hatrack_set_put*(a0: ptr hatrack_set_t, a1: pointer): bool {.lc4m.}

proc hatrack_set_add*(a0: ptr hatrack_set_t, a1: pointer): bool {.lc4m.}

proc hatrack_set_remove*(a0: ptr hatrack_set_t, a1: pointer): bool {.lc4m.}

proc hatrack_set_items*(a0: ptr hatrack_set_t, a1: ptr uint64): pointer {.lc4m.}

proc hatrack_set_items_sort*(a0: ptr hatrack_set_t, a1: ptr uint64): pointer {.lc4m.}

proc hatrack_set_is_eq*(a0: ptr hatrack_set_t, a1: ptr hatrack_set_t): bool {.lc4m.}

proc hatrack_set_is_superset*(
  a0: ptr hatrack_set_t, a1: ptr hatrack_set_t, a2: bool
): bool {.lc4m.}

proc hatrack_set_is_subset*(
  a0: ptr hatrack_set_t, a1: ptr hatrack_set_t, a2: bool
): bool {.lc4m.}

proc hatrack_set_is_disjoint*(
  a0: ptr hatrack_set_t, a1: ptr hatrack_set_t
): bool {.lc4m.}

proc hatrack_set_any_item*(a0: ptr hatrack_set_t, a1: ptr bool): pointer {.lc4m.}

const C4M_CSTR_CTYPE_CONST* = 24 ## From libcon4m/include/core/ffi.h:22:9

proc forkpty*(
  a0: ptr cint, a1: cstring, a2: ptr struct_termios, a3: ptr struct_winsize
): pid_t {.lc4m.}

proc set_linebreaks_utf32*(
  s: ptr int32, len: csize_t, lang: cstring, brks: cstring
): void {.lc4m.}

proc set_linebreaks_utf8_per_code_point*(
  s: ptr int8, len: csize_t, lang: cstring, brks: cstring
): csize_t {.lc4m.}

proc utf8proc_iterate*(a0: ptr uint8, a1: ssize_t, a2: ptr int32): cint {.lc4m.}

proc utf8proc_codepoint_valid*(a0: int32): bool {.lc4m.}

proc utf8proc_encode_char*(a0: int32, a1: ptr uint8): cint {.lc4m.}

proc utf8proc_category*(a0: int32): cp_category_t {.lc4m.}

proc utf8proc_charwidth*(a0: int32): cint {.lc4m.}

proc utf8proc_tolower*(a0: int32): int32 {.lc4m.}

proc utf8proc_toupper*(a0: int32): int32 {.lc4m.}

proc utf8proc_totitle*(a0: uint32): uint32 {.lc4m.}

proc utf8proc_grapheme_break_stateful*(
  a0: int32, a1: int32, a2: ptr int32
): bool {.lc4m.}

proc utf8proc_map*(
  a0: ptr uint8, a1: int32, a2: ptr ptr uint8, a3: utf8proc_option_t
): int32 {.lc4m.}

proc backtrace_create_state*(
  filename: cstring,
  threaded: cint,
  error_callback: backtrace_error_callback,
  data: pointer,
): ptr struct_backtrace_state {.lc4m.}

proc backtrace_full*(
  state: ptr struct_backtrace_state,
  skip: cint,
  callback: backtrace_full_callback,
  error_callback: backtrace_error_callback,
  data: pointer,
): cint {.lc4m.}

proc backtrace_simple*(
  state: ptr struct_backtrace_state,
  skip: cint,
  callback: backtrace_simple_callback,
  error_callback: backtrace_error_callback,
  data: pointer,
): cint {.lc4m.}

proc backtrace_print*(
  state: ptr struct_backtrace_state, skip: cint, a2: ptr FILE
): void {.lc4m.}

proc backtrace_pcinfo*(
  state: ptr struct_backtrace_state,
  pc: uintptr_t,
  callback: backtrace_full_callback,
  error_callback: backtrace_error_callback,
  data: pointer,
): cint {.lc4m.}

proc backtrace_syminfo*(
  state: ptr struct_backtrace_state,
  addr_arg: uintptr_t,
  callback: backtrace_syminfo_callback,
  error_callback: backtrace_error_callback,
  data: pointer,
): cint {.lc4m.}

proc mmm_thread_acquire*(): ptr mmm_thread_t {.lc4m.}

proc mmm_thread_release*(thread: ptr mmm_thread_t): void {.lc4m.}

proc mmm_setthreadfns*(acquirefn: mmm_thread_acquire_func, aux: pointer): void {.lc4m.}

var mmm_epoch* {.importc.}: Atomic[uint64]

proc mmm_retire*(a0: ptr mmm_thread_t, a1: pointer): void {.lc4m.}

proc mmm_start_basic_op*(thread: ptr mmm_thread_t): void {.lc4m.}

proc mmm_start_linearized_op*(thread: ptr mmm_thread_t): uint64 {.lc4m.}

proc mmm_end_op*(thread: ptr mmm_thread_t): void {.lc4m.}

proc mmm_alloc*(size: uint64): pointer {.lc4m.}

proc mmm_alloc_committed*(size: uint64): pointer {.lc4m.}

proc mmm_add_cleanup_handler*(
  ptr_arg: pointer, handler: mmm_cleanup_func, aux: pointer
): void {.lc4m.}

proc mmm_commit_write*(ptr_arg: pointer): void {.lc4m.}

proc mmm_help_commit*(ptr_arg: pointer): void {.lc4m.}

proc mmm_retire_unused*(ptr_arg: pointer): void {.lc4m.}

proc mmm_retire_fast*(thread: ptr mmm_thread_t, ptr_arg: pointer): void {.lc4m.}

proc hatrack_view_delete*(view: ptr hatrack_view_t, num: uint64): void {.lc4m.}

proc hatrack_panic*(msg: cstring): void {.lc4m.}

proc hatrack_setpanicfn*(panicfn: hatrack_panic_func, arg: pointer): void {.lc4m.}

proc crown_new*(): ptr crown_t {.lc4m.}

proc crown_new_size*(a0: cschar): ptr crown_t {.lc4m.}

proc crown_init*(a0: ptr crown_t): void {.lc4m.}

proc crown_init_size*(a0: ptr crown_t, a1: cschar): void {.lc4m.}

proc crown_cleanup*(a0: ptr crown_t): void {.lc4m.}

proc crown_delete*(a0: ptr crown_t): void {.lc4m.}

proc crown_get_mmm*(
  a0: ptr crown_t, a1: ptr mmm_thread_t, a2: hatrack_hash_t, a3: ptr bool
): pointer {.lc4m.}

proc crown_get*(a0: ptr crown_t, a1: hatrack_hash_t, a2: ptr bool): pointer {.lc4m.}

proc crown_put_mmm*(
  a0: ptr crown_t, a1: ptr mmm_thread_t, a2: hatrack_hash_t, a3: pointer, a4: ptr bool
): pointer {.lc4m.}

proc crown_put*(
  a0: ptr crown_t, a1: hatrack_hash_t, a2: pointer, a3: ptr bool
): pointer {.lc4m.}

proc crown_replace_mmm*(
  a0: ptr crown_t, a1: ptr mmm_thread_t, a2: hatrack_hash_t, a3: pointer, a4: ptr bool
): pointer {.lc4m.}

proc crown_replace*(
  a0: ptr crown_t, a1: hatrack_hash_t, a2: pointer, a3: ptr bool
): pointer {.lc4m.}

proc crown_add_mmm*(
  a0: ptr crown_t, a1: ptr mmm_thread_t, a2: hatrack_hash_t, a3: pointer
): bool {.lc4m.}

proc crown_add*(a0: ptr crown_t, a1: hatrack_hash_t, a2: pointer): bool {.lc4m.}

proc crown_remove_mmm*(
  a0: ptr crown_t, a1: ptr mmm_thread_t, a2: hatrack_hash_t, a3: ptr bool
): pointer {.lc4m.}

proc crown_remove*(a0: ptr crown_t, a1: hatrack_hash_t, a2: ptr bool): pointer {.lc4m.}

proc crown_len_mmm*(a0: ptr crown_t, a1: ptr mmm_thread_t): uint64 {.lc4m.}

proc crown_len*(a0: ptr crown_t): uint64 {.lc4m.}

proc crown_view_mmm*(
  a0: ptr crown_t, a1: ptr mmm_thread_t, a2: ptr uint64, a3: bool
): ptr hatrack_view_t {.lc4m.}

proc crown_view*(a0: ptr crown_t, a1: ptr uint64, a2: bool): ptr hatrack_view_t {.lc4m.}

proc crown_view_fast_mmm*(
  a0: ptr crown_t, a1: ptr mmm_thread_t, a2: ptr uint64, a3: bool
): ptr hatrack_view_t {.lc4m.}

proc crown_view_fast*(
  a0: ptr crown_t, a1: ptr uint64, a2: bool
): ptr hatrack_view_t {.lc4m.}

proc crown_view_slow_mmm*(
  a0: ptr crown_t, a1: ptr mmm_thread_t, a2: ptr uint64, a3: bool
): ptr hatrack_view_t {.lc4m.}

proc crown_view_slow*(
  a0: ptr crown_t, a1: ptr uint64, a2: bool
): ptr hatrack_view_t {.lc4m.}

proc woolhat_new*(): ptr woolhat_t {.lc4m.}

proc woolhat_new_size*(a0: cschar): ptr woolhat_t {.lc4m.}

proc woolhat_init*(a0: ptr woolhat_t): void {.lc4m.}

proc woolhat_init_size*(a0: ptr woolhat_t, a1: cschar): void {.lc4m.}

proc woolhat_cleanup*(a0: ptr woolhat_t): void {.lc4m.}

proc woolhat_delete*(a0: ptr woolhat_t): void {.lc4m.}

proc woolhat_set_cleanup_func*(
  a0: ptr woolhat_t, a1: mmm_cleanup_func, a2: pointer
): void {.lc4m.}

proc woolhat_get_mmm*(
  a0: ptr woolhat_t, a1: ptr mmm_thread_t, a2: hatrack_hash_t, a3: ptr bool
): pointer {.lc4m.}

proc woolhat_get*(a0: ptr woolhat_t, a1: hatrack_hash_t, a2: ptr bool): pointer {.lc4m.}

proc woolhat_put_mmm*(
  a0: ptr woolhat_t, a1: ptr mmm_thread_t, a2: hatrack_hash_t, a3: pointer, a4: ptr bool
): pointer {.lc4m.}

proc woolhat_put*(
  a0: ptr woolhat_t, a1: hatrack_hash_t, a2: pointer, a3: ptr bool
): pointer {.lc4m.}

proc woolhat_replace_mmm*(
  a0: ptr woolhat_t, a1: ptr mmm_thread_t, a2: hatrack_hash_t, a3: pointer, a4: ptr bool
): pointer {.lc4m.}

proc woolhat_replace*(
  a0: ptr woolhat_t, a1: hatrack_hash_t, a2: pointer, a3: ptr bool
): pointer {.lc4m.}

proc woolhat_add_mmm*(
  a0: ptr woolhat_t, a1: ptr mmm_thread_t, a2: hatrack_hash_t, a3: pointer
): bool {.lc4m.}

proc woolhat_add*(a0: ptr woolhat_t, a1: hatrack_hash_t, a2: pointer): bool {.lc4m.}

proc woolhat_remove_mmm*(
  a0: ptr woolhat_t, a1: ptr mmm_thread_t, a2: hatrack_hash_t, a3: ptr bool
): pointer {.lc4m.}

proc woolhat_remove*(
  a0: ptr woolhat_t, a1: hatrack_hash_t, a2: ptr bool
): pointer {.lc4m.}

proc woolhat_len_mmm*(a0: ptr woolhat_t, a1: ptr mmm_thread_t): uint64 {.lc4m.}

proc woolhat_len*(a0: ptr woolhat_t): uint64 {.lc4m.}

proc woolhat_view_mmm*(
  a0: ptr woolhat_t, a1: ptr mmm_thread_t, a2: ptr uint64, a3: bool
): ptr hatrack_view_t {.lc4m.}

proc woolhat_view*(
  a0: ptr woolhat_t, a1: ptr uint64, a2: bool
): ptr hatrack_view_t {.lc4m.}

proc woolhat_view_epoch*(
  a0: ptr woolhat_t, a1: ptr uint64, a2: uint64
): ptr hatrack_set_view_t {.lc4m.}

proc hatrack_set_view_delete*(view: ptr hatrack_set_view_t, num: uint64): void {.lc4m.}

proc refhat_new*(): ptr refhat_t {.lc4m.}

proc refhat_new_size*(a0: cschar): ptr refhat_t {.lc4m.}

proc refhat_init*(a0: ptr refhat_t): void {.lc4m.}

proc refhat_init_size*(a0: ptr refhat_t, a1: cschar): void {.lc4m.}

proc refhat_cleanup*(a0: ptr refhat_t): void {.lc4m.}

proc refhat_delete*(a0: ptr refhat_t): void {.lc4m.}

proc refhat_get_mmm*(
  a0: ptr refhat_t, a1: ptr mmm_thread_t, a2: hatrack_hash_t, a3: ptr bool
): pointer {.lc4m.}

proc refhat_get*(a0: ptr refhat_t, a1: hatrack_hash_t, a2: ptr bool): pointer {.lc4m.}

proc refhat_put_mmm*(
  a0: ptr refhat_t, a1: ptr mmm_thread_t, a2: hatrack_hash_t, a3: pointer, a4: ptr bool
): pointer {.lc4m.}

proc refhat_put*(
  a0: ptr refhat_t, a1: hatrack_hash_t, a2: pointer, a3: ptr bool
): pointer {.lc4m.}

proc refhat_replace_mmm*(
  a0: ptr refhat_t, a1: ptr mmm_thread_t, a2: hatrack_hash_t, a3: pointer, a4: ptr bool
): pointer {.lc4m.}

proc refhat_replace*(
  a0: ptr refhat_t, a1: hatrack_hash_t, a2: pointer, a3: ptr bool
): pointer {.lc4m.}

proc refhat_add_mmm*(
  a0: ptr refhat_t, a1: ptr mmm_thread_t, a2: hatrack_hash_t, a3: pointer
): bool {.lc4m.}

proc refhat_add*(a0: ptr refhat_t, a1: hatrack_hash_t, a2: pointer): bool {.lc4m.}

proc refhat_remove_mmm*(
  a0: ptr refhat_t, a1: ptr mmm_thread_t, a2: hatrack_hash_t, a3: ptr bool
): pointer {.lc4m.}

proc refhat_remove*(
  a0: ptr refhat_t, a1: hatrack_hash_t, a2: ptr bool
): pointer {.lc4m.}

proc refhat_len_mmm*(a0: ptr refhat_t, a1: ptr mmm_thread_t): uint64 {.lc4m.}

proc refhat_len*(a0: ptr refhat_t): uint64 {.lc4m.}

proc refhat_view_mmm*(
  a0: ptr refhat_t, a1: ptr mmm_thread_t, a2: ptr uint64, a3: bool
): ptr hatrack_view_t {.lc4m.}

proc refhat_view*(
  a0: ptr refhat_t, a1: ptr uint64, a2: bool
): ptr hatrack_view_t {.lc4m.}

proc hatrack_dict_new*(a0: uint32): ptr hatrack_dict_t {.lc4m.}

proc hatrack_dict_init*(a0: ptr hatrack_dict_t, a1: uint32): void {.lc4m.}

proc hatrack_dict_cleanup*(a0: ptr hatrack_dict_t): void {.lc4m.}

proc hatrack_dict_delete*(a0: ptr hatrack_dict_t): void {.lc4m.}

proc hatrack_dict_set_hash_offset*(a0: ptr hatrack_dict_t, a1: int32): void {.lc4m.}

proc hatrack_dict_set_cache_offset*(a0: ptr hatrack_dict_t, a1: int32): void {.lc4m.}

proc hatrack_dict_set_custom_hash*(
  a0: ptr hatrack_dict_t, a1: hatrack_hash_func_t
): void {.lc4m.}

proc hatrack_dict_set_free_handler*(
  a0: ptr hatrack_dict_t, a1: hatrack_mem_hook_t
): void {.lc4m.}

proc hatrack_dict_set_key_return_hook*(
  a0: ptr hatrack_dict_t, a1: hatrack_mem_hook_t
): void {.lc4m.}

proc hatrack_dict_set_val_return_hook*(
  a0: ptr hatrack_dict_t, a1: hatrack_mem_hook_t
): void {.lc4m.}

proc hatrack_dict_set_consistent_views*(a0: ptr hatrack_dict_t, a1: bool): void {.lc4m.}

proc hatrack_dict_set_sorted_views*(a0: ptr hatrack_dict_t, a1: bool): void {.lc4m.}

proc hatrack_dict_get_consistent_views*(a0: ptr hatrack_dict_t): bool {.lc4m.}

proc hatrack_dict_get_sorted_views*(a0: ptr hatrack_dict_t): bool {.lc4m.}

proc hatrack_dict_get_mmm*(
  a0: ptr hatrack_dict_t, thread: ptr mmm_thread_t, a2: pointer, a3: ptr bool
): pointer {.lc4m.}

proc hatrack_dict_put_mmm*(
  a0: ptr hatrack_dict_t, thread: ptr mmm_thread_t, a2: pointer, a3: pointer
): void {.lc4m.}

proc hatrack_dict_replace_mmm*(
  a0: ptr hatrack_dict_t, thread: ptr mmm_thread_t, a2: pointer, a3: pointer
): bool {.lc4m.}

proc hatrack_dict_add_mmm*(
  a0: ptr hatrack_dict_t, thread: ptr mmm_thread_t, a2: pointer, a3: pointer
): bool {.lc4m.}

proc hatrack_dict_remove_mmm*(
  a0: ptr hatrack_dict_t, thread: ptr mmm_thread_t, a2: pointer
): bool {.lc4m.}

proc hatrack_dict_keys_mmm*(
  a0: ptr hatrack_dict_t, a1: ptr mmm_thread_t, a2: ptr uint64
): ptr hatrack_dict_key_t {.lc4m.}

proc hatrack_dict_values_mmm*(
  a0: ptr hatrack_dict_t, a1: ptr mmm_thread_t, a2: ptr uint64
): ptr hatrack_dict_value_t {.lc4m.}

proc hatrack_dict_items_mmm*(
  a0: ptr hatrack_dict_t, a1: ptr mmm_thread_t, a2: ptr uint64
): ptr hatrack_dict_item_t {.lc4m.}

proc hatrack_dict_keys_sort_mmm*(
  a0: ptr hatrack_dict_t, a1: ptr mmm_thread_t, a2: ptr uint64
): ptr hatrack_dict_key_t {.lc4m.}

proc hatrack_dict_values_sort_mmm*(
  a0: ptr hatrack_dict_t, a1: ptr mmm_thread_t, a2: ptr uint64
): ptr hatrack_dict_value_t {.lc4m.}

proc hatrack_dict_items_sort_mmm*(
  a0: ptr hatrack_dict_t, a1: ptr mmm_thread_t, a2: ptr uint64
): ptr hatrack_dict_item_t {.lc4m.}

proc hatrack_dict_keys_nosort_mmm*(
  a0: ptr hatrack_dict_t, a1: ptr mmm_thread_t, a2: ptr uint64
): ptr hatrack_dict_key_t {.lc4m.}

proc hatrack_dict_values_nosort_mmm*(
  a0: ptr hatrack_dict_t, a1: ptr mmm_thread_t, a2: ptr uint64
): ptr hatrack_dict_value_t {.lc4m.}

proc hatrack_dict_items_nosort_mmm*(
  a0: ptr hatrack_dict_t, a1: ptr mmm_thread_t, a2: ptr uint64
): ptr hatrack_dict_item_t {.lc4m.}

proc hatrack_dict_get*(
  a0: ptr hatrack_dict_t, a1: pointer, a2: ptr bool
): pointer {.lc4m.}

proc hatrack_dict_put*(a0: ptr hatrack_dict_t, a1: pointer, a2: pointer): void {.lc4m.}

proc hatrack_dict_replace*(
  a0: ptr hatrack_dict_t, a1: pointer, a2: pointer
): bool {.lc4m.}

proc hatrack_dict_add*(a0: ptr hatrack_dict_t, a1: pointer, a2: pointer): bool {.lc4m.}

proc hatrack_dict_remove*(a0: ptr hatrack_dict_t, a1: pointer): bool {.lc4m.}

proc hatrack_dict_keys*(
  a0: ptr hatrack_dict_t, a1: ptr uint64
): ptr hatrack_dict_key_t {.lc4m.}

proc hatrack_dict_values*(
  a0: ptr hatrack_dict_t, a1: ptr uint64
): ptr hatrack_dict_value_t {.lc4m.}

proc hatrack_dict_items*(
  a0: ptr hatrack_dict_t, a1: ptr uint64
): ptr hatrack_dict_item_t {.lc4m.}

proc hatrack_dict_keys_sort*(
  a0: ptr hatrack_dict_t, a1: ptr uint64
): ptr hatrack_dict_key_t {.lc4m.}

proc hatrack_dict_values_sort*(
  a0: ptr hatrack_dict_t, a1: ptr uint64
): ptr hatrack_dict_value_t {.lc4m.}

proc hatrack_dict_items_sort*(
  a0: ptr hatrack_dict_t, a1: ptr uint64
): ptr hatrack_dict_item_t {.lc4m.}

proc hatrack_dict_keys_nosort*(
  a0: ptr hatrack_dict_t, a1: ptr uint64
): ptr hatrack_dict_key_t {.lc4m.}

proc hatrack_dict_values_nosort*(
  a0: ptr hatrack_dict_t, a1: ptr uint64
): ptr hatrack_dict_value_t {.lc4m.}

proc hatrack_dict_items_nosort*(
  a0: ptr hatrack_dict_t, a1: ptr uint64
): ptr hatrack_dict_item_t {.lc4m.}

proc hatrack_set_new*(a0: uint32): ptr hatrack_set_t {.lc4m.}

proc hatrack_set_init*(a0: ptr hatrack_set_t, a1: uint32): void {.lc4m.}

proc hatrack_set_cleanup*(a0: ptr hatrack_set_t): void {.lc4m.}

proc hatrack_set_delete*(a0: ptr hatrack_set_t): void {.lc4m.}

proc hatrack_set_set_hash_offset*(a0: ptr hatrack_set_t, a1: int32): void {.lc4m.}

proc hatrack_set_set_cache_offset*(a0: ptr hatrack_set_t, a1: int32): void {.lc4m.}

proc hatrack_set_set_custom_hash*(
  a0: ptr hatrack_set_t, a1: hatrack_hash_func_t
): void {.lc4m.}

proc hatrack_set_set_free_handler*(
  a0: ptr hatrack_set_t, a1: hatrack_mem_hook_t
): void {.lc4m.}

proc hatrack_set_set_return_hook*(
  a0: ptr hatrack_set_t, a1: hatrack_mem_hook_t
): void {.lc4m.}

proc hatrack_set_contains_mmm*(
  a0: ptr hatrack_set_t, a1: ptr mmm_thread_t, a2: pointer
): bool {.lc4m.}

proc hatrack_set_put_mmm*(
  a0: ptr hatrack_set_t, a1: ptr mmm_thread_t, a2: pointer
): bool {.lc4m.}

proc hatrack_set_add_mmm*(
  a0: ptr hatrack_set_t, a1: ptr mmm_thread_t, a2: pointer
): bool {.lc4m.}

proc hatrack_set_remove_mmm*(
  a0: ptr hatrack_set_t, a1: ptr mmm_thread_t, a2: pointer
): bool {.lc4m.}

proc hatrack_set_items_mmm*(
  a0: ptr hatrack_set_t, a1: ptr mmm_thread_t, a2: ptr uint64
): pointer {.lc4m.}

proc hatrack_set_items_sort_mmm*(
  a0: ptr hatrack_set_t, a1: ptr mmm_thread_t, a2: ptr uint64
): pointer {.lc4m.}

proc hatrack_set_any_item_mmm*(
  a0: ptr hatrack_set_t, a1: ptr mmm_thread_t, a2: ptr bool
): pointer {.lc4m.}

proc hatrack_set_is_eq_mmm*(
  a0: ptr hatrack_set_t, a1: ptr mmm_thread_t, a2: ptr hatrack_set_t
): bool {.lc4m.}

proc hatrack_set_is_superset_mmm*(
  a0: ptr hatrack_set_t, a1: ptr mmm_thread_t, a2: ptr hatrack_set_t, a3: bool
): bool {.lc4m.}

proc hatrack_set_is_subset_mmm*(
  a0: ptr hatrack_set_t, a1: ptr mmm_thread_t, a2: ptr hatrack_set_t, a3: bool
): bool {.lc4m.}

proc hatrack_set_is_disjoint_mmm*(
  a0: ptr hatrack_set_t, a1: ptr mmm_thread_t, a2: ptr hatrack_set_t
): bool {.lc4m.}

proc hatrack_set_difference_mmm*(
  a0: ptr hatrack_set_t,
  a1: ptr mmm_thread_t,
  a2: ptr hatrack_set_t,
  a3: ptr hatrack_set_t,
): void {.lc4m.}

proc hatrack_set_union_mmm*(
  a0: ptr hatrack_set_t,
  a1: ptr mmm_thread_t,
  a2: ptr hatrack_set_t,
  a3: ptr hatrack_set_t,
): void {.lc4m.}

proc hatrack_set_intersection_mmm*(
  a0: ptr hatrack_set_t,
  a1: ptr mmm_thread_t,
  a2: ptr hatrack_set_t,
  a3: ptr hatrack_set_t,
): void {.lc4m.}

proc hatrack_set_disjunction_mmm*(
  a0: ptr hatrack_set_t,
  a1: ptr mmm_thread_t,
  a2: ptr hatrack_set_t,
  a3: ptr hatrack_set_t,
): void {.lc4m.}

proc hatrack_set_difference*(
  a0: ptr hatrack_set_t, a1: ptr hatrack_set_t, a2: ptr hatrack_set_t
): void {.lc4m.}

proc hatrack_set_union*(
  a0: ptr hatrack_set_t, a1: ptr hatrack_set_t, a2: ptr hatrack_set_t
): void {.lc4m.}

proc hatrack_set_intersection*(
  a0: ptr hatrack_set_t, a1: ptr hatrack_set_t, a2: ptr hatrack_set_t
): void {.lc4m.}

proc hatrack_set_disjunction*(
  a0: ptr hatrack_set_t, a1: ptr hatrack_set_t, a2: ptr hatrack_set_t
): void {.lc4m.}

proc flexarray_new*(a0: uint64): ptr flexarray_t {.lc4m.}

proc flexarray_init*(a0: ptr flexarray_t, a1: uint64): void {.lc4m.}

proc flexarray_set_ret_callback*(
  a0: ptr flexarray_t, a1: flex_callback_t
): void {.lc4m.}

proc flexarray_set_eject_callback*(
  a0: ptr flexarray_t, a1: flex_callback_t
): void {.lc4m.}

proc flexarray_cleanup*(a0: ptr flexarray_t): void {.lc4m.}

proc flexarray_delete*(a0: ptr flexarray_t): void {.lc4m.}

proc flexarray_get_mmm*(
  a0: ptr flexarray_t, a1: ptr mmm_thread_t, a2: uint64, a3: ptr cint
): pointer {.lc4m.}

proc flexarray_get*(a0: ptr flexarray_t, a1: uint64, a2: ptr cint): pointer {.lc4m.}

proc flexarray_set_mmm*(
  a0: ptr flexarray_t, a1: ptr mmm_thread_t, a2: uint64, a3: pointer
): bool {.lc4m.}

proc flexarray_set*(a0: ptr flexarray_t, a1: uint64, a2: pointer): bool {.lc4m.}

proc flexarray_grow_mmm*(
  a0: ptr flexarray_t, a1: ptr mmm_thread_t, a2: uint64
): void {.lc4m.}

proc flexarray_grow*(a0: ptr flexarray_t, a1: uint64): void {.lc4m.}

proc flexarray_shrink_mmm*(
  a0: ptr flexarray_t, a1: ptr mmm_thread_t, a2: uint64
): void {.lc4m.}

proc flexarray_shrink*(a0: ptr flexarray_t, a1: uint64): void {.lc4m.}

proc flexarray_len_mmm*(a0: ptr flexarray_t, a1: ptr mmm_thread_t): uint64 {.lc4m.}

proc flexarray_len*(a0: ptr flexarray_t): uint64 {.lc4m.}

proc flexarray_view_mmm*(
  a0: ptr flexarray_t, a1: ptr mmm_thread_t
): ptr flex_view_t {.lc4m.}

proc flexarray_view*(a0: ptr flexarray_t): ptr flex_view_t {.lc4m.}

proc flexarray_view_next*(a0: ptr flex_view_t, a1: ptr cint): pointer {.lc4m.}

proc flexarray_view_delete_mmm*(
  a0: ptr flex_view_t, a1: ptr mmm_thread_t
): void {.lc4m.}

proc flexarray_view_delete*(a0: ptr flex_view_t): void {.lc4m.}

proc flexarray_view_get*(
  a0: ptr flex_view_t, a1: uint64, a2: ptr cint
): pointer {.lc4m.}

proc flexarray_view_len*(a0: ptr flex_view_t): uint64 {.lc4m.}

proc flexarray_add_mmm*(
  a0: ptr flexarray_t, a1: ptr mmm_thread_t, a2: ptr flexarray_t
): ptr flexarray_t {.lc4m.}

proc flexarray_add*(a0: ptr flexarray_t, a1: ptr flexarray_t): ptr flexarray_t {.lc4m.}

proc hatrack_setmallocfns*(a0: ptr hatrack_mem_manager_t): void {.lc4m.}

proc internal_hatrack_malloc*(
  size: csize_t
): pointer {.cdecl, importc: "_hatrack_malloc".}

proc internal_hatrack_zalloc*(
  size: csize_t
): pointer {.cdecl, importc: "_hatrack_zalloc".}

proc internal_hatrack_realloc*(
  oldptr: pointer, oldsize: csize_t, newsize: csize_t
): pointer {.cdecl, importc: "_hatrack_realloc".}

proc internal_hatrack_free*(
  oldptr: pointer, oldsize: csize_t
): void {.cdecl, importc: "_hatrack_free".}

proc XXH_malloc*(s: csize_t): pointer {.lc4m.}

proc XXH_free*(p: pointer, s: csize_t): void {.lc4m.}

proc XXH_memcpy*(dest: pointer, src: pointer, size: csize_t): pointer {.lc4m.}

proc XXH_read32*(memPtr: pointer): xxh_u32 {.lc4m.}

proc XXH_swap32*(x: xxh_u32): xxh_u32 {.lc4m.}

proc XXH_readLE32*(ptr_arg: pointer): xxh_u32 {.lc4m.}

proc XXH_readBE32*(ptr_arg: pointer): xxh_u32 {.lc4m.}

proc XXH_readLE32_align*(ptr_arg: pointer, align: XXH_alignment): xxh_u32 {.lc4m.}

proc XXH32_round*(acc: xxh_u32, input: xxh_u32): xxh_u32 {.lc4m.}

proc XXH32_avalanche*(h32: xxh_u32): xxh_u32 {.lc4m.}

proc XXH32_finalize*(
  h32: xxh_u32, ptr_arg: ptr xxh_u8, len: csize_t, align: XXH_alignment
): xxh_u32 {.lc4m.}

proc XXH32_endian_align*(
  input: ptr xxh_u8, len: csize_t, seed: xxh_u32, align: XXH_alignment
): xxh_u32 {.lc4m.}

proc XXH_read64*(memPtr: pointer): xxh_u64 {.lc4m.}

proc XXH_swap64*(x: xxh_u64): xxh_u64 {.lc4m.}

proc XXH_readLE64*(ptr_arg: pointer): xxh_u64 {.lc4m.}

proc XXH_readBE64*(ptr_arg: pointer): xxh_u64 {.lc4m.}

proc XXH_readLE64_align*(ptr_arg: pointer, align: XXH_alignment): xxh_u64 {.lc4m.}

proc XXH64_round*(acc: xxh_u64, input: xxh_u64): xxh_u64 {.lc4m.}

proc XXH64_mergeRound*(acc: xxh_u64, val: xxh_u64): xxh_u64 {.lc4m.}

proc XXH64_avalanche*(h64: xxh_u64): xxh_u64 {.lc4m.}

proc XXH64_finalize*(
  h64: xxh_u64, ptr_arg: ptr xxh_u8, len: csize_t, align: XXH_alignment
): xxh_u64 {.lc4m.}

proc XXH64_endian_align*(
  input: ptr xxh_u8, len: csize_t, seed: xxh_u64, align: XXH_alignment
): xxh_u64 {.lc4m.}

var XXH3_kSecret*: array[192, xxh_u8]

proc XXH_mult64to128*(lhs: xxh_u64, rhs: xxh_u64): XXH_NAMESPACEXXH128_hash_t {.lc4m.}

proc XXH3_mul128_fold64*(lhs: xxh_u64, rhs: xxh_u64): xxh_u64 {.lc4m.}

proc XXH_xorshift64*(v64: xxh_u64, shift: cint): xxh_u64 {.lc4m.}

proc XXH3_avalanche*(h64: xxh_u64): XXH64_hash_t {.lc4m.}

proc XXH3_rrmxmx*(h64: xxh_u64, len: xxh_u64): XXH64_hash_t {.lc4m.}

proc XXH3_len_1to3_64b*(
  input: ptr xxh_u8, len: csize_t, secret: ptr xxh_u8, seed: XXH64_hash_t
): XXH64_hash_t {.lc4m.}

proc XXH3_len_4to8_64b*(
  input: ptr xxh_u8, len: csize_t, secret: ptr xxh_u8, seed: XXH64_hash_t
): XXH64_hash_t {.lc4m.}

proc XXH3_len_9to16_64b*(
  input: ptr xxh_u8, len: csize_t, secret: ptr xxh_u8, seed: XXH64_hash_t
): XXH64_hash_t {.lc4m.}

proc XXH3_len_0to16_64b*(
  input: ptr xxh_u8, len: csize_t, secret: ptr xxh_u8, seed: XXH64_hash_t
): XXH64_hash_t {.lc4m.}

proc XXH3_mix16B*(
  input: ptr xxh_u8, secret: ptr xxh_u8, seed64: xxh_u64
): xxh_u64 {.lc4m.}

proc XXH3_len_17to128_64b*(
  input: ptr xxh_u8,
  len: csize_t,
  secret: ptr xxh_u8,
  secretSize: csize_t,
  seed: XXH64_hash_t,
): XXH64_hash_t {.lc4m.}

proc XXH3_len_129to240_64b*(
  input: ptr xxh_u8,
  len: csize_t,
  secret: ptr xxh_u8,
  secretSize: csize_t,
  seed: XXH64_hash_t,
): XXH64_hash_t {.lc4m.}

proc XXH_writeLE64*(dst: pointer, v64: xxh_u64): void {.lc4m.}

proc XXH3_accumulate_512_scalar*(
  acc: pointer, input: pointer, secret: pointer
): void {.lc4m.}

proc XXH3_scrambleAcc_scalar*(acc: pointer, secret: pointer): void {.lc4m.}

proc XXH3_initCustomSecret_scalar*(
  customSecret: pointer, seed64: xxh_u64
): void {.lc4m.}

proc XXH3_accumulate*(
  acc: ptr xxh_u64,
  input: ptr xxh_u8,
  secret: ptr xxh_u8,
  nbStripes: csize_t,
  f_acc512: XXH3_f_accumulate_512,
): void {.lc4m.}

proc XXH3_hashLong_internal_loop*(
  acc: ptr xxh_u64,
  input: ptr xxh_u8,
  len: csize_t,
  secret: ptr xxh_u8,
  secretSize: csize_t,
  f_acc512: XXH3_f_accumulate_512,
  f_scramble: XXH3_f_scrambleAcc,
): void {.lc4m.}

proc XXH3_mix2Accs*(acc: ptr xxh_u64, secret: ptr xxh_u8): xxh_u64 {.lc4m.}

proc XXH3_mergeAccs*(
  acc: ptr xxh_u64, secret: ptr xxh_u8, start: xxh_u64
): XXH64_hash_t {.lc4m.}

proc XXH3_hashLong_64b_internal*(
  input: pointer,
  len: csize_t,
  secret: pointer,
  secretSize: csize_t,
  f_acc512: XXH3_f_accumulate_512,
  f_scramble: XXH3_f_scrambleAcc,
): XXH64_hash_t {.lc4m.}

proc XXH3_hashLong_64b_withSecret*(
  input: pointer,
  len: csize_t,
  seed64: XXH64_hash_t,
  secret: ptr xxh_u8,
  secretLen: csize_t,
): XXH64_hash_t {.lc4m.}

proc XXH3_hashLong_64b_default*(
  input: pointer,
  len: csize_t,
  seed64: XXH64_hash_t,
  secret: ptr xxh_u8,
  secretLen: csize_t,
): XXH64_hash_t {.lc4m.}

proc XXH3_hashLong_64b_withSeed_internal*(
  input: pointer,
  len: csize_t,
  seed: XXH64_hash_t,
  f_acc512: XXH3_f_accumulate_512,
  f_scramble: XXH3_f_scrambleAcc,
  f_initSec: XXH3_f_initCustomSecret,
): XXH64_hash_t {.lc4m.}

proc XXH3_hashLong_64b_withSeed*(
  input: pointer,
  len: csize_t,
  seed: XXH64_hash_t,
  secret: ptr xxh_u8,
  secretLen: csize_t,
): XXH64_hash_t {.lc4m.}

proc XXH3_64bits_internal*(
  input: pointer,
  len: csize_t,
  seed64: XXH64_hash_t,
  secret: pointer,
  secretLen: csize_t,
  f_hashLong: XXH3_hashLong64_f,
): XXH64_hash_t {.lc4m.}

proc XXH_alignedMalloc*(s: csize_t, align: csize_t): pointer {.lc4m.}

proc XXH_alignedFree*(p: pointer, s: csize_t, align: csize_t): void {.lc4m.}

proc XXH3_reset_internal*(
  statePtr: ptr XXH_NAMESPACEXXH3_state_t,
  seed: XXH64_hash_t,
  secret: pointer,
  secretSize: csize_t,
): void {.lc4m.}

proc XXH3_consumeStripes*(
  acc: ptr xxh_u64,
  nbStripesSoFarPtr: ptr csize_t,
  nbStripesPerBlock: csize_t,
  input: ptr xxh_u8,
  nbStripes: csize_t,
  secret: ptr xxh_u8,
  secretLimit: csize_t,
  f_acc512: XXH3_f_accumulate_512,
  f_scramble: XXH3_f_scrambleAcc,
): void {.lc4m.}

proc XXH3_update*(
  state: ptr XXH_NAMESPACEXXH3_state_t,
  input: ptr xxh_u8,
  len: csize_t,
  f_acc512: XXH3_f_accumulate_512,
  f_scramble: XXH3_f_scrambleAcc,
): XXH_NAMESPACEXXH_errorcode {.lc4m.}

proc XXH3_digest_long*(
  acc: ptr XXH64_hash_t, state: ptr XXH_NAMESPACEXXH3_state_t, secret: ptr uint8
): void {.lc4m.}

proc XXH3_len_1to3_128b*(
  input: ptr xxh_u8, len: csize_t, secret: ptr xxh_u8, seed: XXH64_hash_t
): XXH_NAMESPACEXXH128_hash_t {.lc4m.}

proc XXH3_len_4to8_128b*(
  input: ptr xxh_u8, len: csize_t, secret: ptr xxh_u8, seed: XXH64_hash_t
): XXH_NAMESPACEXXH128_hash_t {.lc4m.}

proc XXH3_len_9to16_128b*(
  input: ptr xxh_u8, len: csize_t, secret: ptr xxh_u8, seed: XXH64_hash_t
): XXH_NAMESPACEXXH128_hash_t {.lc4m.}

proc XXH3_len_0to16_128b*(
  input: ptr xxh_u8, len: csize_t, secret: ptr xxh_u8, seed: XXH64_hash_t
): XXH_NAMESPACEXXH128_hash_t {.lc4m.}

proc XXH128_mix32B*(
  acc: XXH_NAMESPACEXXH128_hash_t,
  input_1: ptr xxh_u8,
  input_2: ptr xxh_u8,
  secret: ptr xxh_u8,
  seed: XXH64_hash_t,
): XXH_NAMESPACEXXH128_hash_t {.lc4m.}

proc XXH3_len_17to128_128b*(
  input: ptr xxh_u8,
  len: csize_t,
  secret: ptr xxh_u8,
  secretSize: csize_t,
  seed: XXH64_hash_t,
): XXH_NAMESPACEXXH128_hash_t {.lc4m.}

proc XXH3_len_129to240_128b*(
  input: ptr xxh_u8,
  len: csize_t,
  secret: ptr xxh_u8,
  secretSize: csize_t,
  seed: XXH64_hash_t,
): XXH_NAMESPACEXXH128_hash_t {.lc4m.}

proc XXH3_hashLong_128b_internal*(
  input: pointer,
  len: csize_t,
  secret: ptr xxh_u8,
  secretSize: csize_t,
  f_acc512: XXH3_f_accumulate_512,
  f_scramble: XXH3_f_scrambleAcc,
): XXH_NAMESPACEXXH128_hash_t {.lc4m.}

proc XXH3_hashLong_128b_default*(
  input: pointer,
  len: csize_t,
  seed64: XXH64_hash_t,
  secret: pointer,
  secretLen: csize_t,
): XXH_NAMESPACEXXH128_hash_t {.lc4m.}

proc XXH3_hashLong_128b_withSecret*(
  input: pointer,
  len: csize_t,
  seed64: XXH64_hash_t,
  secret: pointer,
  secretLen: csize_t,
): XXH_NAMESPACEXXH128_hash_t {.lc4m.}

proc XXH3_hashLong_128b_withSeed_internal*(
  input: pointer,
  len: csize_t,
  seed64: XXH64_hash_t,
  f_acc512: XXH3_f_accumulate_512,
  f_scramble: XXH3_f_scrambleAcc,
  f_initSec: XXH3_f_initCustomSecret,
): XXH_NAMESPACEXXH128_hash_t {.lc4m.}

proc XXH3_hashLong_128b_withSeed*(
  input: pointer,
  len: csize_t,
  seed64: XXH64_hash_t,
  secret: pointer,
  secretLen: csize_t,
): XXH_NAMESPACEXXH128_hash_t {.lc4m.}

proc XXH3_128bits_internal*(
  input: pointer,
  len: csize_t,
  seed64: XXH64_hash_t,
  secret: pointer,
  secretLen: csize_t,
  f_hl128: XXH3_hashLong128_f,
): XXH_NAMESPACEXXH128_hash_t {.lc4m.}

proc queue_new*(): ptr queue_t {.lc4m.}

proc queue_new_size*(a0: cschar): ptr queue_t {.lc4m.}

proc queue_init*(a0: ptr queue_t): void {.lc4m.}

proc queue_init_size*(a0: ptr queue_t, a1: cschar): void {.lc4m.}

proc queue_cleanup*(a0: ptr queue_t): void {.lc4m.}

proc queue_delete*(a0: ptr queue_t): void {.lc4m.}

proc queue_len_mmm*(a0: ptr queue_t, a1: ptr mmm_thread_t): uint64 {.lc4m.}

proc queue_len*(a0: ptr queue_t): uint64 {.lc4m.}

proc queue_enqueue_mmm*(
  a0: ptr queue_t, a1: ptr mmm_thread_t, a2: pointer
): void {.lc4m.}

proc queue_enqueue*(a0: ptr queue_t, a1: pointer): void {.lc4m.}

proc queue_dequeue_mmm*(
  a0: ptr queue_t, a1: ptr mmm_thread_t, a2: ptr bool
): pointer {.lc4m.}

proc queue_dequeue*(a0: ptr queue_t, a1: ptr bool): pointer {.lc4m.}

proc hatstack_new*(a0: uint64): ptr hatstack_t {.lc4m.}

proc hatstack_init*(a0: ptr hatstack_t, a1: uint64): void {.lc4m.}

proc hatstack_cleanup*(a0: ptr hatstack_t): void {.lc4m.}

proc hatstack_delete*(a0: ptr hatstack_t): void {.lc4m.}

proc hatstack_push_mmm*(
  a0: ptr hatstack_t, a1: ptr mmm_thread_t, a2: pointer
): void {.lc4m.}

proc hatstack_push*(a0: ptr hatstack_t, a1: pointer): void {.lc4m.}

proc hatstack_pop_mmm*(
  a0: ptr hatstack_t, a1: ptr mmm_thread_t, a2: ptr bool
): pointer {.lc4m.}

proc hatstack_pop*(a0: ptr hatstack_t, a1: ptr bool): pointer {.lc4m.}

proc hatstack_peek_mmm*(
  a0: ptr hatstack_t, a1: ptr mmm_thread_t, a2: ptr bool
): pointer {.lc4m.}

proc hatstack_peek*(a0: ptr hatstack_t, a1: ptr bool): pointer {.lc4m.}

proc hatstack_view_mmm*(
  a0: ptr hatstack_t, a1: ptr mmm_thread_t
): ptr stack_view_t {.lc4m.}

proc hatstack_view*(a0: ptr hatstack_t): ptr stack_view_t {.lc4m.}

proc hatstack_view_next*(a0: ptr stack_view_t, a1: ptr bool): pointer {.lc4m.}

proc hatstack_view_delete_mmm*(
  a0: ptr stack_view_t, a1: ptr mmm_thread_t
): void {.lc4m.}

proc hatstack_view_delete*(a0: ptr stack_view_t): void {.lc4m.}

proc hatring_new*(a0: uint64): ptr hatring_t {.lc4m.}

proc hatring_init*(a0: ptr hatring_t, a1: uint64): void {.lc4m.}

proc hatring_cleanup*(a0: ptr hatring_t): void {.lc4m.}

proc hatring_delete*(a0: ptr hatring_t): void {.lc4m.}

proc hatring_enqueue*(a0: ptr hatring_t, a1: pointer): uint32 {.lc4m.}

proc hatring_dequeue*(a0: ptr hatring_t, a1: ptr bool): pointer {.lc4m.}

proc hatring_dequeue_w_epoch*(
  a0: ptr hatring_t, a1: ptr bool, a2: ptr uint32
): pointer {.lc4m.}

proc hatring_view*(a0: ptr hatring_t): ptr hatring_view_t {.lc4m.}

proc hatring_view_next*(a0: ptr hatring_view_t, a1: ptr bool): pointer {.lc4m.}

proc hatring_view_delete*(a0: ptr hatring_view_t): void {.lc4m.}

proc hatring_set_drop_handler*(
  a0: ptr hatring_t, a1: hatring_drop_handler
): void {.lc4m.}

proc logring_new*(a0: uint64, a1: uint64): ptr logring_t {.lc4m.}

proc logring_init*(a0: ptr logring_t, a1: uint64, a2: uint64): void {.lc4m.}

proc logring_cleanup*(a0: ptr logring_t): void {.lc4m.}

proc logring_delete*(a0: ptr logring_t): void {.lc4m.}

proc logring_enqueue_mmm*(
  a0: ptr logring_t, a1: ptr mmm_thread_t, a2: pointer, a3: uint64
): void {.lc4m.}

proc logring_enqueue*(a0: ptr logring_t, a1: pointer, a2: uint64): void {.lc4m.}

proc logring_dequeue_mmm*(
  a0: ptr logring_t, a1: ptr mmm_thread_t, a2: pointer, a3: ptr uint64
): bool {.lc4m.}

proc logring_dequeue*(a0: ptr logring_t, a1: pointer, a2: ptr uint64): bool {.lc4m.}

proc logring_view_mmm*(
  a0: ptr logring_t, a1: ptr mmm_thread_t, a2: bool
): ptr logring_view_t {.lc4m.}

proc logring_view*(a0: ptr logring_t, a1: bool): ptr logring_view_t {.lc4m.}

proc logring_view_next*(a0: ptr logring_view_t, a1: ptr uint64): pointer {.lc4m.}

proc logring_view_delete_mmm*(
  a0: ptr logring_view_t, a1: ptr mmm_thread_t
): void {.lc4m.}

proc logring_view_delete*(a0: ptr logring_view_t): void {.lc4m.}

proc hatrack_zarray_new*(a0: uint32, a1: uint32): ptr hatrack_zarray_t {.lc4m.}

proc hatrack_zarray_cell_address*(
  a0: ptr hatrack_zarray_t, a1: uint32
): pointer {.lc4m.}

proc hatrack_zarray_new_cell*(
  a0: ptr hatrack_zarray_t, a1: ptr pointer
): uint32 {.lc4m.}

proc hatrack_zarray_len*(a0: ptr hatrack_zarray_t): uint32 {.lc4m.}

proc hatrack_zarray_delete*(a0: ptr hatrack_zarray_t): void {.lc4m.}

proc hatrack_zarray_unsafe_copy*(
  a0: ptr hatrack_zarray_t
): ptr hatrack_zarray_t {.lc4m.}

proc c4m_pat_repr*(
  a0: ptr c4m_tpat_node_t, a1: c4m_pattern_fmt_fn
): ptr c4m_tree_node_t {.lc4m.}

var
  ffi_type_void* {.importc.}: c4m_ffi_type
  ffi_type_float* {.importc.}: c4m_ffi_type
  ffi_type_double* {.importc.}: c4m_ffi_type
  ffi_type_pointer* {.importc.}: c4m_ffi_type

proc c4m_init*(a0: cint, a1: ptr cstring, a2: ptr cstring): void {.lc4m.}

var
  c4m_stashed_argv* {.importc.}: ptr cstring
  c4m_stashed_envp* {.importc.}: ptr cstring

proc c4m_get_program_arguments*(): ptr c4m_list_t {.lc4m.}

proc c4m_get_argv0*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_get_env*(a0: ptr c4m_utf8_t): ptr c4m_utf8_t {.lc4m.}

proc c4m_environment*(): ptr c4m_dict_t {.lc4m.}

proc c4m_path_search*(a0: ptr c4m_utf8_t, a1: ptr c4m_utf8_t): ptr c4m_utf8_t {.lc4m.}

proc c4m_con4m_root*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_system_module_path*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_add_static_symbols*(): void {.lc4m.}

var
  con4m_path* {.importc.}: ptr c4m_list_t
  con4m_extensions* {.importc.}: ptr c4m_set_t

proc c4m_get_kargs*(): ptr c4m_karg_info_t {.lc4m, varargs.}

proc c4m_pass_kargs*(a0: cint): ptr c4m_karg_info_t {.lc4m, varargs.}

proc c4m_get_kargs_and_count*(a0: va_list, a1: ptr cint): ptr c4m_karg_info_t {.lc4m.}

var c4m_gc_guard* {.importc.}: uint64

proc c4m_new_arena*(a0: csize_t, a1: ptr hatrack_zarray_t): ptr c4m_arena_t {.lc4m.}

proc c4m_delete_arena*(a0: ptr c4m_arena_t): void {.lc4m.}

proc c4m_expand_arena*(a0: csize_t, a1: ptr ptr c4m_arena_t): void {.lc4m.}

proc c4m_collect_arena*(a0: ptr c4m_arena_t): ptr c4m_arena_t {.lc4m.}

proc c4m_gc_resize*(ptr_arg: pointer, len: csize_t): pointer {.lc4m.}

proc c4m_gc_thread_collect*(): void {.lc4m.}

proc c4m_is_read_only_memory*(a0: pointer): bool {.lc4m.}

proc c4m_gc_set_finalize_callback*(a0: c4m_system_finalizer_fn): void {.lc4m.}

proc internal_c4m_arena_register_root*(
  a0: ptr c4m_arena_t, a1: pointer, a2: uint64
): void {.cdecl, importc: "_c4m_arena_register_root".}

proc internal_c4m_gc_register_root*(
  a0: pointer, a1: uint64
): void {.cdecl, importc: "_c4m_gc_register_root".}

proc c4m_arena_remove_root*(arena: ptr c4m_arena_t, ptr_arg: pointer): void {.lc4m.}

proc c4m_gc_remove_root*(ptr_arg: pointer): void {.lc4m.}

proc internal_c4m_gc_raw_alloc*(
  a0: csize_t, a1: c4m_mem_scan_fn
): pointer {.cdecl, importc: "_c4m_gc_raw_alloc".}

proc internal_c4m_gc_raw_alloc_with_finalizer*(
  a0: csize_t, a1: c4m_mem_scan_fn
): pointer {.cdecl, importc: "_c4m_gc_raw_alloc_with_finalizer".}

proc c4m_alloc_from_arena*(
  a0: ptr ptr c4m_arena_t, a1: csize_t, a2: c4m_mem_scan_fn, a3: bool
): pointer {.lc4m.}

var c4m_gc_show_heap_stats_on* {.importc.}: cint

proc c4m_initialize_gc*(): void {.lc4m.}

proc c4m_gc_heap_stats*(a0: ptr uint64, a1: ptr uint64, a2: ptr uint64): void {.lc4m.}

proc c4m_gc_add_hold*(a0: c4m_obj_t): void {.lc4m.}

proc c4m_gc_remove_hold*(a0: c4m_obj_t): void {.lc4m.}

proc c4m_internal_stash_heap*(): ptr c4m_arena_t {.lc4m.}

proc c4m_internal_unstash_heap*(): void {.lc4m.}

proc c4m_internal_set_heap*(a0: ptr c4m_arena_t): void {.lc4m.}

proc c4m_internal_lock_then_unstash_heap*(): void {.lc4m.}

proc c4m_get_heap_bounds*(a0: ptr uint64, a1: ptr uint64, a2: ptr uint64): void {.lc4m.}

proc c4m_gc_register_collect_fns*(a0: c4m_gc_hook, a1: c4m_gc_hook): void {.lc4m.}

proc c4m_find_alloc*(a0: pointer): ptr c4m_alloc_hdr {.lc4m.}

proc c4m_in_heap*(a0: pointer): bool {.lc4m.}

proc c4m_header_gc_bits*(a0: ptr uint64, a1: ptr c4m_base_obj_t): void {.lc4m.}

proc c4m_scan_header_only*(a0: ptr uint64, a1: cint): void {.lc4m.}

var c4m_base_type_info* {.importc.}: array[51, c4m_dt_info_t]

proc internal_c4m_new*(
  type_arg: ptr c4m_type_t
): c4m_obj_t {.cdecl, varargs, importc: "_c4m_new".}

proc c4m_repr*(a0: pointer, a1: ptr c4m_type_t): ptr c4m_str_t {.lc4m.}

proc c4m_to_str*(a0: pointer, a1: ptr c4m_type_t): ptr c4m_str_t {.lc4m.}

proc c4m_can_coerce*(a0: ptr c4m_type_t, a1: ptr c4m_type_t): bool {.lc4m.}

proc c4m_coerce*(
  a0: pointer, a1: ptr c4m_type_t, a2: ptr c4m_type_t
): c4m_obj_t {.lc4m.}

proc c4m_coerce_object*(a0: c4m_obj_t, a1: ptr c4m_type_t): c4m_obj_t {.lc4m.}

proc c4m_copy_object*(a0: c4m_obj_t): c4m_obj_t {.lc4m.}

proc c4m_copy_object_of_type*(a0: c4m_obj_t, a1: ptr c4m_type_t): c4m_obj_t {.lc4m.}

proc c4m_add*(a0: c4m_obj_t, a1: c4m_obj_t): c4m_obj_t {.lc4m.}

proc c4m_sub*(a0: c4m_obj_t, a1: c4m_obj_t): c4m_obj_t {.lc4m.}

proc c4m_mul*(a0: c4m_obj_t, a1: c4m_obj_t): c4m_obj_t {.lc4m.}

proc c4m_div*(a0: c4m_obj_t, a1: c4m_obj_t): c4m_obj_t {.lc4m.}

proc c4m_mod*(a0: c4m_obj_t, a1: c4m_obj_t): c4m_obj_t {.lc4m.}

proc c4m_eq*(a0: ptr c4m_type_t, a1: c4m_obj_t, a2: c4m_obj_t): bool {.lc4m.}

proc c4m_lt*(a0: ptr c4m_type_t, a1: c4m_obj_t, a2: c4m_obj_t): bool {.lc4m.}

proc c4m_gt*(a0: ptr c4m_type_t, a1: c4m_obj_t, a2: c4m_obj_t): bool {.lc4m.}

proc c4m_len*(a0: c4m_obj_t): int64 {.lc4m.}

proc c4m_index_get*(a0: c4m_obj_t, a1: c4m_obj_t): c4m_obj_t {.lc4m.}

proc c4m_index_set*(a0: c4m_obj_t, a1: c4m_obj_t, a2: c4m_obj_t): void {.lc4m.}

proc c4m_slice_get*(a0: c4m_obj_t, a1: int64, a2: int64): c4m_obj_t {.lc4m.}

proc c4m_slice_set*(a0: c4m_obj_t, a1: int64, a2: int64, a3: c4m_obj_t): void {.lc4m.}

proc c4m_value_obj_repr*(a0: c4m_obj_t): ptr c4m_str_t {.lc4m.}

proc c4m_value_obj_to_str*(a0: c4m_obj_t): ptr c4m_str_t {.lc4m.}

proc c4m_get_item_type*(a0: c4m_obj_t): ptr c4m_type_t {.lc4m.}

proc c4m_get_view*(a0: c4m_obj_t, a1: ptr int64): pointer {.lc4m.}

proc c4m_container_literal*(
  a0: ptr c4m_type_t, a1: ptr c4m_list_t, a2: ptr c4m_utf8_t
): c4m_obj_t {.lc4m.}

proc c4m_finalize_allocation*(a0: ptr c4m_base_obj_t): void {.lc4m.}

var
  c4m_i8_type* {.importc.}: c4m_vtable_t
  c4m_u8_type* {.importc.}: c4m_vtable_t
  c4m_i32_type* {.importc.}: c4m_vtable_t
  c4m_u32_type* {.importc.}: c4m_vtable_t
  c4m_i64_type* {.importc.}: c4m_vtable_t
  c4m_u64_type* {.importc.}: c4m_vtable_t
  c4m_bool_type* {.importc.}: c4m_vtable_t
  c4m_float_type* {.importc.}: c4m_vtable_t
  c4m_u8str_vtable* {.importc.}: c4m_vtable_t
  c4m_u32str_vtable* {.importc.}: c4m_vtable_t
  c4m_buffer_vtable* {.importc.}: c4m_vtable_t
  c4m_grid_vtable* {.importc.}: c4m_vtable_t
  c4m_renderable_vtable* {.importc.}: c4m_vtable_t
  c4m_flexarray_vtable* {.importc.}: c4m_vtable_t
  c4m_queue_vtable* {.importc.}: c4m_vtable_t
  c4m_ring_vtable* {.importc.}: c4m_vtable_t
  c4m_logring_vtable* {.importc.}: c4m_vtable_t
  c4m_stack_vtable* {.importc.}: c4m_vtable_t
  c4m_dict_vtable* {.importc.}: c4m_vtable_t
  c4m_set_vtable* {.importc.}: c4m_vtable_t
  c4m_list_vtable* {.importc.}: c4m_vtable_t
  c4m_sha_vtable* {.importc.}: c4m_vtable_t
  c4m_render_style_vtable* {.importc.}: c4m_vtable_t
  c4m_exception_vtable* {.importc.}: c4m_vtable_t
  c4m_type_spec_vtable* {.importc.}: c4m_vtable_t
  c4m_tree_vtable* {.importc.}: c4m_vtable_t
  c4m_tuple_vtable* {.importc.}: c4m_vtable_t
  c4m_mixed_vtable* {.importc.}: c4m_vtable_t
  c4m_ipaddr_vtable* {.importc.}: c4m_vtable_t
  c4m_stream_vtable* {.importc.}: c4m_vtable_t
  c4m_vm_vtable* {.importc.}: c4m_vtable_t
  c4m_parse_node_vtable* {.importc.}: c4m_vtable_t
  c4m_callback_vtable* {.importc.}: c4m_vtable_t
  c4m_flags_vtable* {.importc.}: c4m_vtable_t
  c4m_box_vtable* {.importc.}: c4m_vtable_t
  c4m_basic_http_vtable* {.importc.}: c4m_vtable_t
  c4m_datetime_vtable* {.importc.}: c4m_vtable_t
  c4m_date_vtable* {.importc.}: c4m_vtable_t
  c4m_time_vtable* {.importc.}: c4m_vtable_t
  c4m_size_vtable* {.importc.}: c4m_vtable_t
  c4m_duration_vtable* {.importc.}: c4m_vtable_t

proc c4m_lookup_color*(a0: ptr c4m_utf8_t): c4m_color_t {.lc4m.}

proc c4m_to_vga*(truecolor: c4m_color_t): c4m_color_t {.lc4m.}

proc c4m_list_get*(a0: ptr c4m_list_t, a1: int64, a2: ptr bool): pointer {.lc4m.}

proc c4m_list_append*(list: ptr c4m_list_t, item: pointer): void {.lc4m.}

proc c4m_list_add_if_unique*(
  list: ptr c4m_list_t,
  item: pointer,
  fn: proc(a0: pointer, a1: pointer): bool {.cdecl.},
): void {.lc4m.}

proc c4m_list_pop*(list: ptr c4m_list_t): pointer {.lc4m.}

proc c4m_list_plus_eq*(a0: ptr c4m_list_t, a1: ptr c4m_list_t): void {.lc4m.}

proc c4m_list_plus*(a0: ptr c4m_list_t, a1: ptr c4m_list_t): ptr c4m_list_t {.lc4m.}

proc c4m_list_set*(a0: ptr c4m_list_t, a1: int64, a2: pointer): bool {.lc4m.}

proc c4m_list*(a0: ptr c4m_type_t): ptr c4m_list_t {.lc4m.}

proc c4m_list_len*(a0: ptr c4m_list_t): int64 {.lc4m.}

proc c4m_list_get_slice*(
  a0: ptr c4m_list_t, a1: int64, a2: int64
): ptr c4m_list_t {.lc4m.}

proc c4m_list_set_slice*(
  a0: ptr c4m_list_t, a1: int64, a2: int64, a3: ptr c4m_list_t
): void {.lc4m.}

proc c4m_list_contains*(a0: ptr c4m_list_t, a1: c4m_obj_t): bool {.lc4m.}

proc c4m_list_copy*(a0: ptr c4m_list_t): ptr c4m_list_t {.lc4m.}

proc c4m_list_shallow_copy*(a0: ptr c4m_list_t): ptr c4m_list_t {.lc4m.}

proc c4m_list_sort*(a0: ptr c4m_list_t, a1: c4m_sort_fn): void {.lc4m.}

proc c4m_list_resize*(a0: ptr c4m_list_t, a1: csize_t): void {.lc4m.}

proc c4m_universe_init*(a0: ptr c4m_type_universe_t): void {.lc4m.}

proc c4m_universe_get*(
  a0: ptr c4m_type_universe_t, a1: c4m_type_hash_t
): ptr c4m_type_t {.lc4m.}

proc c4m_universe_put*(a0: ptr c4m_type_universe_t, a1: ptr c4m_type_t): bool {.lc4m.}

proc c4m_universe_add*(a0: ptr c4m_type_universe_t, a1: ptr c4m_type_t): bool {.lc4m.}

proc c4m_universe_attempt_to_add*(
  a0: ptr c4m_type_universe_t, a1: ptr c4m_type_t
): ptr c4m_type_t {.lc4m.}

proc c4m_universe_forward*(
  a0: ptr c4m_type_universe_t, a1: ptr c4m_type_t, a2: ptr c4m_type_t
): void {.lc4m.}

proc c4m_type_resolve*(a0: ptr c4m_type_t): ptr c4m_type_t {.lc4m.}

proc c4m_type_is_concrete*(a0: ptr c4m_type_t): bool {.lc4m.}

proc c4m_type_copy*(a0: ptr c4m_type_t): ptr c4m_type_t {.lc4m.}

proc c4m_get_builtin_type*(a0: c4m_builtin_t): ptr c4m_type_t {.lc4m.}

proc c4m_unify*(a0: ptr c4m_type_t, a1: ptr c4m_type_t): ptr c4m_type_t {.lc4m.}

proc c4m_type_flist*(a0: ptr c4m_type_t): ptr c4m_type_t {.lc4m.}

proc c4m_type_list*(a0: ptr c4m_type_t): ptr c4m_type_t {.lc4m.}

proc c4m_type_tree*(a0: ptr c4m_type_t): ptr c4m_type_t {.lc4m.}

proc c4m_type_queue*(a0: ptr c4m_type_t): ptr c4m_type_t {.lc4m.}

proc c4m_type_ring*(a0: ptr c4m_type_t): ptr c4m_type_t {.lc4m.}

proc c4m_type_stack*(a0: ptr c4m_type_t): ptr c4m_type_t {.lc4m.}

proc c4m_type_set*(a0: ptr c4m_type_t): ptr c4m_type_t {.lc4m.}

proc c4m_type_box*(a0: ptr c4m_type_t): ptr c4m_type_t {.lc4m.}

proc c4m_type_dict*(a0: ptr c4m_type_t, a1: ptr c4m_type_t): ptr c4m_type_t {.lc4m.}

proc c4m_type_tuple*(a0: int64): ptr c4m_type_t {.lc4m, varargs.}

proc c4m_type_tuple_from_xlist*(a0: ptr c4m_list_t): ptr c4m_type_t {.lc4m.}

proc c4m_type_fn*(
  a0: ptr c4m_type_t, a1: ptr c4m_list_t, a2: bool
): ptr c4m_type_t {.lc4m.}

proc c4m_type_fn_va*(a0: ptr c4m_type_t, a1: int64): ptr c4m_type_t {.lc4m, varargs.}

proc c4m_type_varargs_fn*(
  a0: ptr c4m_type_t, a1: int64
): ptr c4m_type_t {.lc4m, varargs.}

proc c4m_lock_type*(a0: ptr c4m_type_t): void {.lc4m.}

proc c4m_get_promotion_type*(
  a0: ptr c4m_type_t, a1: ptr c4m_type_t, a2: ptr cint
): ptr c4m_type_t {.lc4m.}

proc c4m_new_typevar*(): ptr c4m_type_t {.lc4m.}

proc c4m_initialize_global_types*(): void {.lc4m.}

proc c4m_calculate_type_hash*(node: ptr c4m_type_t): c4m_type_hash_t {.lc4m.}

proc c4m_get_list_bitfield*(): ptr uint64 {.lc4m.}

proc c4m_get_dict_bitfield*(): ptr uint64 {.lc4m.}

proc c4m_get_set_bitfield*(): ptr uint64 {.lc4m.}

proc c4m_get_tuple_bitfield*(): ptr uint64 {.lc4m.}

proc c4m_get_all_containers_bitfield*(): ptr uint64 {.lc4m.}

proc c4m_get_no_containers_bitfield*(): ptr uint64 {.lc4m.}

proc c4m_get_num_bitfield_words*(): cint {.lc4m.}

proc c4m_partial_inference*(a0: ptr c4m_type_t): bool {.lc4m.}

proc c4m_list_syntax_possible*(a0: ptr c4m_type_t): bool {.lc4m.}

proc c4m_dict_syntax_possible*(a0: ptr c4m_type_t): bool {.lc4m.}

proc c4m_set_syntax_possible*(a0: ptr c4m_type_t): bool {.lc4m.}

proc c4m_tuple_syntax_possible*(a0: ptr c4m_type_t): bool {.lc4m.}

proc c4m_remove_list_options*(a0: ptr c4m_type_t): void {.lc4m.}

proc c4m_remove_dict_options*(a0: ptr c4m_type_t): void {.lc4m.}

proc c4m_remove_set_options*(a0: ptr c4m_type_t): void {.lc4m.}

proc c4m_remove_tuple_options*(a0: ptr c4m_type_t): void {.lc4m.}

proc c4m_type_has_list_syntax*(a0: ptr c4m_type_t): bool {.lc4m.}

proc c4m_type_has_dict_syntax*(a0: ptr c4m_type_t): bool {.lc4m.}

proc c4m_type_has_set_syntax*(a0: ptr c4m_type_t): bool {.lc4m.}

proc c4m_type_has_tuple_syntax*(a0: ptr c4m_type_t): bool {.lc4m.}

proc c4m_type_cmp_exact*(
  a0: ptr c4m_type_t, a1: ptr c4m_type_t
): c4m_type_exact_result_t {.lc4m.}

var c4m_bi_types* {.importc.}: array[51, ptr c4m_type_t]

proc c4m_set_next_typevar_fn*(a0: c4m_next_typevar_fn): void {.lc4m.}

proc c4m_tree_children*(a0: ptr c4m_tree_node_t): ptr c4m_list_t {.lc4m.}

proc c4m_tree_get_child*(
  a0: ptr c4m_tree_node_t, a1: int64
): ptr c4m_tree_node_t {.lc4m.}

proc c4m_tree_add_node*(
  a0: ptr c4m_tree_node_t, a1: pointer
): ptr c4m_tree_node_t {.lc4m.}

proc c4m_tree_prepend_node*(
  a0: ptr c4m_tree_node_t, a1: pointer
): ptr c4m_tree_node_t {.lc4m.}

proc c4m_tree_adopt_node*(
  a0: ptr c4m_tree_node_t, a1: ptr c4m_tree_node_t
): void {.lc4m.}

proc c4m_tree_adopt_and_prepend*(
  a0: ptr c4m_tree_node_t, a1: ptr c4m_tree_node_t
): void {.lc4m.}

proc c4m_tree_str_transform*(
  a0: ptr c4m_tree_node_t, fn: proc(a0: pointer): ptr c4m_str_t {.cdecl.}
): ptr c4m_tree_node_t {.lc4m.}

proc c4m_tree_walk*(a0: ptr c4m_tree_node_t, a1: c4m_walker_fn): void {.lc4m.}

proc internal_c4m_tpat_find*(
  a0: pointer, a1: int64
): ptr c4m_tpat_node_t {.cdecl, varargs, importc: "_c4m_tpat_find".}

proc internal_c4m_tpat_match*(
  a0: pointer, a1: int64
): ptr c4m_tpat_node_t {.cdecl, varargs, importc: "_c4m_tpat_match".}

proc internal_c4m_tpat_opt_match*(
  a0: pointer, a1: int64
): ptr c4m_tpat_node_t {.cdecl, varargs, importc: "_c4m_tpat_opt_match".}

proc internal_c4m_tpat_n_m_match*(
  a0: pointer, a1: int64, a2: int64, a3: int64
): ptr c4m_tpat_node_t {.cdecl, varargs, importc: "_c4m_tpat_n_m_match".}

proc c4m_tpat_content_find*(a0: pointer, a1: int64): ptr c4m_tpat_node_t {.lc4m.}

proc c4m_tpat_content_match*(a0: pointer, a1: int64): ptr c4m_tpat_node_t {.lc4m.}

proc internal_c4m_tpat_opt_content_match*(
  a0: pointer, a1: int64
): ptr c4m_tpat_node_t {.cdecl, importc: "_c4m_tpat_opt_content_match".}

proc c4m_tpat_n_m_content_match*(
  a0: pointer, a1: int64, a2: int64, a3: int64
): ptr c4m_tpat_node_t {.lc4m.}

proc c4m_tree_match*(
  a0: ptr c4m_tree_node_t,
  a1: ptr c4m_tpat_node_t,
  a2: c4m_cmp_fn,
  matches: ptr ptr c4m_list_t,
): bool {.lc4m.}

proc c4m_buffer_add*(a0: ptr c4m_buf_t, a1: ptr c4m_buf_t): ptr c4m_buf_t {.lc4m.}

proc c4m_buffer_join*(a0: ptr c4m_list_t, a1: ptr c4m_buf_t): ptr c4m_buf_t {.lc4m.}

proc c4m_buffer_len*(a0: ptr c4m_buf_t): int64 {.lc4m.}

proc c4m_buffer_resize*(a0: ptr c4m_buf_t, a1: uint64): void {.lc4m.}

proc c4m_buf_to_utf8_string*(a0: ptr c4m_buf_t): ptr c4m_utf8_t {.lc4m.}

proc c4m_tuple_set*(a0: ptr c4m_tuple_t, a1: int64, a2: pointer): void {.lc4m.}

proc c4m_tuple_get*(a0: ptr c4m_tuple_t, a1: int64): pointer {.lc4m.}

proc c4m_tuple_len*(a0: ptr c4m_tuple_t): int64 {.lc4m.}

proc c4m_str_copy*(s: ptr c4m_str_t): ptr c4m_str_t {.lc4m.}

proc c4m_str_concat*(a0: ptr c4m_str_t, a1: ptr c4m_str_t): ptr c4m_utf32_t {.lc4m.}

proc c4m_to_utf8*(a0: ptr c4m_utf32_t): ptr c4m_utf8_t {.lc4m.}

proc c4m_to_utf32*(a0: ptr c4m_utf8_t): ptr c4m_utf32_t {.lc4m.}

proc c4m_from_file*(a0: ptr c4m_str_t, a1: ptr cint): ptr c4m_utf8_t {.lc4m.}

proc c4m_utf8_validate*(a0: ptr c4m_utf8_t): int64 {.lc4m.}

proc c4m_str_slice*(a0: ptr c4m_str_t, a1: int64, a2: int64): ptr c4m_utf32_t {.lc4m.}

proc c4m_utf8_repeat*(a0: c4m_codepoint_t, a1: int64): ptr c4m_utf8_t {.lc4m.}

proc c4m_utf32_repeat*(a0: c4m_codepoint_t, a1: int64): ptr c4m_utf32_t {.lc4m.}

proc internal_c4m_str_strip*(
  s: ptr c4m_str_t
): ptr c4m_utf32_t {.cdecl, varargs, importc: "_c4m_str_strip".}

proc internal_c4m_str_truncate*(
  s: ptr c4m_str_t, a1: int64
): ptr c4m_str_t {.cdecl, varargs, importc: "_c4m_str_truncate".}

proc internal_c4m_str_join*(
  a0: ptr c4m_list_t, a1: ptr c4m_str_t
): ptr c4m_str_t {.cdecl, varargs, importc: "_c4m_str_join".}

proc c4m_str_from_int*(n: int64): ptr c4m_utf8_t {.lc4m.}

proc internal_c4m_str_find*(
  a0: ptr c4m_str_t, a1: ptr c4m_str_t
): int64 {.cdecl, varargs, importc: "_c4m_str_find".}

proc internal_c4m_str_rfind*(
  a0: ptr c4m_str_t, a1: ptr c4m_str_t
): int64 {.cdecl, varargs, importc: "_c4m_str_rfind".}

proc c4m_cstring*(s: cstring, len: int64): ptr c4m_utf8_t {.lc4m.}

proc c4m_rich*(a0: ptr c4m_utf8_t, style: ptr c4m_utf8_t): ptr c4m_utf8_t {.lc4m.}

proc c4m_index*(a0: ptr c4m_str_t, a1: int64): c4m_codepoint_t {.lc4m.}

proc c4m_str_can_coerce_to*(a0: ptr c4m_type_t, a1: ptr c4m_type_t): bool {.lc4m.}

proc c4m_str_coerce_to*(a0: ptr c4m_str_t, a1: ptr c4m_type_t): c4m_obj_t {.lc4m.}

proc c4m_str_split*(a0: ptr c4m_str_t, a1: ptr c4m_str_t): ptr c4m_list_t {.lc4m.}

proc c4m_str_fsplit*(
  a0: ptr c4m_str_t, a1: ptr c4m_str_t
): ptr struct_flexarray_t {.lc4m.}

proc c4m_str_starts_with*(a0: ptr c4m_str_t, a1: ptr c4m_str_t): bool {.lc4m.}

proc c4m_str_ends_with*(a0: ptr c4m_str_t, a1: ptr c4m_str_t): bool {.lc4m.}

proc c4m_str_wrap*(a0: ptr c4m_str_t, a1: int64, a2: int64): ptr c4m_list_t {.lc4m.}

proc c4m_str_upper*(a0: ptr c4m_str_t): ptr c4m_utf32_t {.lc4m.}

proc c4m_str_lower*(a0: ptr c4m_str_t): ptr c4m_utf32_t {.lc4m.}

proc c4m_title_case*(a0: ptr c4m_str_t): ptr c4m_utf32_t {.lc4m.}

proc c4m_str_pad*(a0: ptr c4m_str_t, a1: int64): ptr c4m_str_t {.lc4m.}

proc c4m_str_to_hex*(a0: ptr c4m_str_t, a1: bool): ptr c4m_utf8_t {.lc4m.}

proc c4m_rich_lit*(a0: cstring): ptr c4m_utf8_t {.lc4m.}

var
  c4m_empty_string_const* {.importc.}: ptr c4m_utf8_t
  c4m_newline_const* {.importc.}: ptr c4m_utf8_t
  c4m_crlf_const* {.importc.}: ptr c4m_utf8_t

proc c4m_str_render_len*(a0: ptr c4m_str_t): int64 {.lc4m.}

proc c4m_u8_map*(a0: ptr c4m_list_t): ptr c4m_list_t {.lc4m.}

proc c4m_str_eq*(a0: ptr c4m_str_t, a1: ptr c4m_str_t): bool {.lc4m.}

var
  c4m_pmap_str* {.importc.}: array[2, uint64]
  c4m_minimum_break_slots* {.importc.}: cint

proc c4m_get_grapheme_breaks*(
  a0: ptr c4m_str_t, a1: int32, a2: int32
): ptr c4m_break_info_t {.lc4m.}

proc c4m_get_line_breaks*(a0: ptr c4m_str_t): ptr c4m_break_info_t {.lc4m.}

proc c4m_get_all_line_break_ops*(a0: ptr c4m_str_t): ptr c4m_break_info_t {.lc4m.}

proc c4m_wrap_text*(
  a0: ptr c4m_str_t, a1: int32, a2: int32
): ptr c4m_break_info_t {.lc4m.}

proc c4m_utf8_ansi_render*(
  s: ptr c4m_utf8_t, outstream: ptr c4m_stream_t
): void {.lc4m.}

proc c4m_utf32_ansi_render*(
  s: ptr c4m_utf32_t, start_ix: int32, end_ix: int32, outstream: ptr c4m_stream_t
): void {.lc4m.}

proc c4m_ansi_render*(s: ptr c4m_str_t, out_arg: ptr c4m_stream_t): void {.lc4m.}

proc c4m_ansi_render_to_width*(
  s: ptr c4m_str_t, width: int32, hang: int32, out_arg: ptr c4m_stream_t
): void {.lc4m.}

proc c4m_ansi_render_len*(s: ptr c4m_str_t): csize_t {.lc4m.}

proc c4m_hexl*(
  a0: pointer, a1: int32, a2: uint64, a3: int32, a4: cstring
): cstring {.lc4m.}

proc internal_c4m_hex_dump*(
  a0: pointer, a1: uint32
): ptr c4m_utf8_t {.cdecl, varargs, importc: "_c4m_hex_dump".}

var c4m_hex_map* {.importc.}: array[16, uint8]

proc c4m_apply_bg_color*(style: c4m_style_t, name: ptr c4m_utf8_t): c4m_style_t {.lc4m.}

proc c4m_apply_fg_color*(style: c4m_style_t, name: ptr c4m_utf8_t): c4m_style_t {.lc4m.}

proc c4m_style_gaps*(a0: ptr c4m_str_t, a1: c4m_style_t): void {.lc4m.}

proc c4m_str_layer_style*(
  a0: ptr c4m_str_t, a1: c4m_style_t, a2: c4m_style_t
): void {.lc4m.}

var default_style* {.importc.}: c4m_style_t

proc c4m_set_style*(name: cstring, style: ptr c4m_render_style_t): void {.lc4m.}

proc c4m_lookup_cell_style*(name: cstring): ptr c4m_render_style_t {.lc4m.}

proc c4m_install_default_styles*(): void {.lc4m.}

var c4m_registered_borders* {.importc.}: ptr c4m_border_theme_t

proc c4m_style_exists*(name: cstring): bool {.lc4m.}

proc c4m_layer_styles*(
  a0: ptr c4m_render_style_t, a1: ptr c4m_render_style_t
): void {.lc4m.}

proc c4m_grid_set_all_contents*(a0: ptr c4m_grid_t, a1: ptr c4m_list_t): void {.lc4m.}

proc c4m_grid_flow*(items: uint64): ptr c4m_grid_t {.lc4m, varargs.}

proc c4m_callout*(s: ptr c4m_str_t): ptr c4m_grid_t {.lc4m.}

proc c4m_grid_to_str*(a0: ptr c4m_grid_t): ptr c4m_utf32_t {.lc4m.}

proc internal_c4m_ordered_list*(
  a0: ptr c4m_list_t
): ptr c4m_grid_t {.cdecl, varargs, importc: "_c4m_ordered_list".}

proc internal_c4m_unordered_list*(
  a0: ptr c4m_list_t
): ptr c4m_grid_t {.cdecl, varargs, importc: "_c4m_unordered_list".}

proc internal_c4m_grid_tree*(
  a0: ptr c4m_tree_node_t
): ptr c4m_grid_t {.cdecl, varargs, importc: "_c4m_grid_tree".}

proc internal_c4m_grid_render*(
  a0: ptr c4m_grid_t
): ptr c4m_list_t {.cdecl, varargs, importc: "_c4m_grid_render".}

proc c4m_set_column_props*(
  a0: ptr c4m_grid_t, a1: cint, a2: ptr c4m_render_style_t
): void {.lc4m.}

proc c4m_row_column_props*(
  a0: ptr c4m_grid_t, a1: cint, a2: ptr c4m_render_style_t
): void {.lc4m.}

proc c4m_set_column_style*(a0: ptr c4m_grid_t, a1: cint, a2: cstring): void {.lc4m.}

proc c4m_set_row_style*(a0: ptr c4m_grid_t, a1: cint, a2: cstring): void {.lc4m.}

proc c4m_grid_add_col_span*(
  grid: ptr c4m_grid_t,
  contents: ptr c4m_renderable_t,
  row: int64,
  start_col: int64,
  num_cols: int64,
): void {.lc4m.}

proc c4m_apply_container_style*(a0: ptr c4m_renderable_t, a1: cstring): void {.lc4m.}

proc c4m_install_renderable*(
  a0: ptr c4m_grid_t, a1: ptr c4m_renderable_t, a2: cint, a3: cint, a4: cint, a5: cint
): bool {.lc4m.}

proc c4m_grid_expand_columns*(a0: ptr c4m_grid_t, a1: uint64): void {.lc4m.}

proc c4m_grid_expand_rows*(a0: ptr c4m_grid_t, a1: uint64): void {.lc4m.}

proc c4m_grid_add_row*(a0: ptr c4m_grid_t, a1: c4m_obj_t): void {.lc4m.}

proc c4m_grid*(
  a0: cint,
  a1: cint,
  a2: cstring,
  a3: cstring,
  a4: cstring,
  a5: cint,
  a6: cint,
  a7: cint,
): ptr c4m_grid_t {.lc4m.}

proc c4m_grid_horizontal_flow*(
  a0: ptr c4m_list_t, a1: uint64, a2: uint64, a3: cstring, a4: cstring
): ptr c4m_grid_t {.lc4m.}

proc c4m_grid_set_cell_contents*(
  a0: ptr c4m_grid_t, a1: cint, a2: cint, a3: c4m_obj_t
): void {.lc4m.}

proc c4m_terminal_dimensions*(cols: ptr csize_t, rows: ptr csize_t): void {.lc4m.}

proc c4m_termcap_set_raw_mode*(termcap: ptr struct_termios): void {.lc4m.}

proc c4m_sb_read_one*(a0: cint, a1: cstring, a2: csize_t): ssize_t {.lc4m.}

proc c4m_sb_write_data*(a0: cint, a1: cstring, a2: csize_t): bool {.lc4m.}

proc c4m_sb_party_fd*(party: ptr c4m_party_t): cint {.lc4m.}

proc c4m_sb_init_party_listener*(
  a0: ptr c4m_switchboard_t,
  a1: ptr c4m_party_t,
  a2: cint,
  a3: c4m_accept_cb_t,
  a4: bool,
  a5: bool,
): void {.lc4m.}

proc c4m_sb_new_party_listener*(
  a0: ptr c4m_switchboard_t, a1: cint, a2: c4m_accept_cb_t, a3: bool, a4: bool
): ptr c4m_party_t {.lc4m.}

proc c4m_sb_init_party_fd*(
  a0: ptr c4m_switchboard_t,
  a1: ptr c4m_party_t,
  a2: cint,
  a3: cint,
  a4: bool,
  a5: bool,
  a6: bool,
): void {.lc4m.}

proc c4m_sb_new_party_fd*(
  a0: ptr c4m_switchboard_t, a1: cint, a2: cint, a3: bool, a4: bool, a5: bool
): ptr c4m_party_t {.lc4m.}

proc c4m_sb_init_party_input_buf*(
  a0: ptr c4m_switchboard_t,
  a1: ptr c4m_party_t,
  a2: cstring,
  a3: csize_t,
  a4: bool,
  a5: bool,
): void {.lc4m.}

proc c4m_sb_new_party_input_buf*(
  a0: ptr c4m_switchboard_t, a1: cstring, a2: csize_t, a3: bool, a4: bool
): ptr c4m_party_t {.lc4m.}

proc c4m_sb_party_input_buf_new_string*(
  a0: ptr c4m_party_t, a1: cstring, a2: csize_t, a3: bool, a4: bool
): void {.lc4m.}

proc c4m_sb_init_party_output_buf*(
  a0: ptr c4m_switchboard_t, a1: ptr c4m_party_t, a2: cstring, a3: csize_t
): void {.lc4m.}

proc c4m_sb_new_party_output_buf*(
  a0: ptr c4m_switchboard_t, a1: cstring, a2: csize_t
): ptr c4m_party_t {.lc4m.}

proc c4m_sb_init_party_callback*(
  a0: ptr c4m_switchboard_t, a1: ptr c4m_party_t, a2: c4m_sb_cb_t
): void {.lc4m.}

proc c4m_sb_new_party_callback*(
  a0: ptr c4m_switchboard_t, a1: c4m_sb_cb_t
): ptr c4m_party_t {.lc4m.}

proc c4m_sb_monitor_pid*(
  a0: ptr c4m_switchboard_t,
  a1: pid_t,
  a2: ptr c4m_party_t,
  a3: ptr c4m_party_t,
  a4: ptr c4m_party_t,
  a5: bool,
): void {.lc4m.}

proc c4m_sb_get_extra*(a0: ptr c4m_switchboard_t): pointer {.lc4m.}

proc c4m_sb_set_extra*(a0: ptr c4m_switchboard_t, a1: pointer): void {.lc4m.}

proc c4m_sb_get_party_extra*(a0: ptr c4m_party_t): pointer {.lc4m.}

proc c4m_sb_set_party_extra*(a0: ptr c4m_party_t, a1: pointer): void {.lc4m.}

proc c4m_sb_route*(
  a0: ptr c4m_switchboard_t, a1: ptr c4m_party_t, a2: ptr c4m_party_t
): bool {.lc4m.}

proc c4m_sb_pause_route*(
  a0: ptr c4m_switchboard_t, a1: ptr c4m_party_t, a2: ptr c4m_party_t
): bool {.lc4m.}

proc c4m_sb_resume_route*(
  a0: ptr c4m_switchboard_t, a1: ptr c4m_party_t, a2: ptr c4m_party_t
): bool {.lc4m.}

proc c4m_sb_route_is_active*(
  a0: ptr c4m_switchboard_t, a1: ptr c4m_party_t, a2: ptr c4m_party_t
): bool {.lc4m.}

proc c4m_sb_route_is_paused*(
  a0: ptr c4m_switchboard_t, a1: ptr c4m_party_t, a2: ptr c4m_party_t
): bool {.lc4m.}

proc c4m_sb_route_is_subscribed*(
  a0: ptr c4m_switchboard_t, a1: ptr c4m_party_t, a2: ptr c4m_party_t
): bool {.lc4m.}

proc c4m_sb_init*(a0: ptr c4m_switchboard_t, a1: csize_t): void {.lc4m.}

proc c4m_sb_set_io_timeout*(
  a0: ptr c4m_switchboard_t, a1: ptr struct_timeval
): void {.lc4m.}

proc c4m_sb_clear_io_timeout*(a0: ptr c4m_switchboard_t): void {.lc4m.}

proc c4m_sb_destroy*(a0: ptr c4m_switchboard_t, a1: bool): void {.lc4m.}

proc c4m_sb_operate_switchboard*(a0: ptr c4m_switchboard_t, a1: bool): bool {.lc4m.}

proc c4m_sb_get_results*(
  a0: ptr c4m_switchboard_t, a1: ptr c4m_capture_result_t
): void {.lc4m.}

proc c4m_sb_result_get_capture*(
  a0: ptr c4m_capture_result_t, a1: cstring, a2: bool
): cstring {.lc4m.}

proc c4m_sb_result_destroy*(a0: ptr c4m_capture_result_t): void {.lc4m.}

proc c4m_new_party*(): ptr c4m_party_t {.lc4m.}

proc c4m_subproc_init*(
  a0: ptr c4m_subproc_t, a1: cstring, a2: ptr UncheckedArray[cstring], a3: bool
): void {.lc4m.}

proc c4m_subproc_set_envp*(
  a0: ptr c4m_subproc_t, a1: ptr UncheckedArray[cstring]
): bool {.lc4m.}

proc c4m_subproc_pass_to_stdin*(
  a0: ptr c4m_subproc_t, a1: cstring, a2: csize_t, a3: bool
): bool {.lc4m.}

proc c4m_subproc_set_passthrough*(
  a0: ptr c4m_subproc_t, a1: uint8, a2: bool
): bool {.lc4m.}

proc c4m_subproc_set_capture*(a0: ptr c4m_subproc_t, a1: uint8, a2: bool): bool {.lc4m.}

proc c4m_subproc_set_io_callback*(
  a0: ptr c4m_subproc_t, a1: uint8, a2: c4m_sb_cb_t
): bool {.lc4m.}

proc c4m_subproc_set_timeout*(
  a0: ptr c4m_subproc_t, a1: ptr struct_timeval
): void {.lc4m.}

proc c4m_subproc_clear_timeout*(a0: ptr c4m_subproc_t): void {.lc4m.}

proc c4m_subproc_use_pty*(a0: ptr c4m_subproc_t): bool {.lc4m.}

proc c4m_subproc_set_startup_callback*(
  a0: ptr c4m_subproc_t, a1: proc(a0: pointer): void {.cdecl.}
): bool {.lc4m.}

proc c4m_subproc_get_pty_fd*(a0: ptr c4m_subproc_t): cint {.lc4m.}

proc c4m_subproc_start*(a0: ptr c4m_subproc_t): void {.lc4m.}

proc c4m_subproc_poll*(a0: ptr c4m_subproc_t): bool {.lc4m.}

proc c4m_subproc_run*(a0: ptr c4m_subproc_t): void {.lc4m.}

proc c4m_subproc_close*(a0: ptr c4m_subproc_t): void {.lc4m.}

proc c4m_subproc_get_pid*(a0: ptr c4m_subproc_t): pid_t {.lc4m.}

proc c4m_sp_result_capture*(
  a0: ptr c4m_capture_result_t, a1: cstring, a2: ptr csize_t
): cstring {.lc4m.}

proc c4m_subproc_get_capture*(
  a0: ptr c4m_subproc_t, a1: cstring, a2: ptr csize_t
): cstring {.lc4m.}

proc c4m_subproc_get_exit*(a0: ptr c4m_subproc_t, a1: bool): cint {.lc4m.}

proc c4m_subproc_get_errno*(a0: ptr c4m_subproc_t, a1: bool): cint {.lc4m.}

proc c4m_subproc_get_signal*(a0: ptr c4m_subproc_t, a1: bool): cint {.lc4m.}

proc c4m_subproc_set_parent_termcap*(
  a0: ptr c4m_subproc_t, a1: ptr struct_termios
): void {.lc4m.}

proc c4m_subproc_set_child_termcap*(
  a0: ptr c4m_subproc_t, a1: ptr struct_termios
): void {.lc4m.}

proc c4m_subproc_set_extra*(a0: ptr c4m_subproc_t, a1: pointer): void {.lc4m.}

proc c4m_subproc_get_extra*(a0: ptr c4m_subproc_t): pointer {.lc4m.}

proc c4m_subproc_pause_passthrough*(a0: ptr c4m_subproc_t, a1: uint8): void {.lc4m.}

proc c4m_subproc_resume_passthrough*(a0: ptr c4m_subproc_t, a1: uint8): void {.lc4m.}

proc c4m_subproc_pause_capture*(a0: ptr c4m_subproc_t, a1: uint8): void {.lc4m.}

proc c4m_subproc_resume_capture*(a0: ptr c4m_subproc_t, a1: uint8): void {.lc4m.}

proc c4m_subproc_status_check*(a0: ptr c4m_monitor_t, a1: bool): void {.lc4m.}

proc internal_c4m_alloc_exception*(
  s: cstring
): ptr c4m_exception_t {.cdecl, varargs, importc: "_c4m_alloc_exception".}

proc internal_c4m_alloc_str_exception*(
  s: ptr c4m_utf8_t
): ptr c4m_exception_t {.cdecl, varargs, importc: "_c4m_alloc_str_exception".}

proc c4m_exception_push_frame*(a0: ptr jmp_buf): ptr c4m_exception_stack_t {.lc4m.}

proc c4m_exception_free_frame*(
  a0: ptr c4m_exception_frame_t, a1: ptr c4m_exception_stack_t
): void {.lc4m.}

proc c4m_exception_uncaught*(a0: ptr c4m_exception_t): void {.lc4m.}

proc c4m_exception_raise*(a0: ptr c4m_exception_t, a1: cstring, a2: cint): void {.lc4m.}

proc c4m_repr_exception_stack_no_vm*(a0: ptr c4m_utf8_t): ptr c4m_utf8_t {.lc4m.}

proc c4m_exception_register_uncaught_handler*(
  a0: proc(a0: ptr c4m_exception_t): void {.cdecl.}
): void {.lc4m.}

var compiler_exception_stack* {.importc: "__exception_stack".}: c4m_exception_stack_t

proc c4m_stream_raw_read*(
  a0: ptr c4m_stream_t, a1: int64, a2: cstring
): ptr c4m_obj_t {.lc4m.}

proc c4m_stream_raw_write*(
  a0: ptr c4m_stream_t, a1: int64, a2: cstring
): csize_t {.lc4m.}

proc c4m_stream_write_object*(
  a0: ptr c4m_stream_t, a1: c4m_obj_t, a2: bool
): void {.lc4m.}

proc c4m_stream_at_eof*(a0: ptr c4m_stream_t): bool {.lc4m.}

proc c4m_stream_get_location*(a0: ptr c4m_stream_t): int64 {.lc4m.}

proc c4m_stream_set_location*(a0: ptr c4m_stream_t, a1: int64): void {.lc4m.}

proc c4m_stream_close*(a0: ptr c4m_stream_t): void {.lc4m.}

proc c4m_stream_flush*(a0: ptr c4m_stream_t): void {.lc4m.}

proc internal_c4m_print*(a0: c4m_obj_t): void {.cdecl, varargs, importc: "_c4m_print".}

proc c4m_stream_read_all*(a0: ptr c4m_stream_t): ptr c4m_obj_t {.lc4m.}

proc c4m_get_stdin*(): ptr c4m_stream_t {.lc4m.}

proc c4m_get_stdout*(): ptr c4m_stream_t {.lc4m.}

proc c4m_get_stderr*(): ptr c4m_stream_t {.lc4m.}

proc c4m_init_std_streams*(): void {.lc4m.}

proc c4m_marshal_cstring*(a0: cstring, a1: ptr c4m_stream_t): void {.lc4m.}

proc c4m_unmarshal_cstring*(a0: ptr c4m_stream_t): cstring {.lc4m.}

proc c4m_marshal_i64*(a0: int64, a1: ptr c4m_stream_t): void {.lc4m.}

proc c4m_unmarshal_i64*(a0: ptr c4m_stream_t): int64 {.lc4m.}

proc c4m_marshal_i32*(a0: int32, a1: ptr c4m_stream_t): void {.lc4m.}

proc c4m_unmarshal_i32*(a0: ptr c4m_stream_t): int32 {.lc4m.}

proc c4m_marshal_i16*(a0: int16, a1: ptr c4m_stream_t): void {.lc4m.}

proc c4m_unmarshal_i16*(a0: ptr c4m_stream_t): int16 {.lc4m.}

proc c4m_sub_marshal*(
  a0: c4m_obj_t, a1: ptr c4m_stream_t, a2: ptr c4m_dict_t, a3: ptr int64
): void {.lc4m.}

proc c4m_sub_unmarshal*(a0: ptr c4m_stream_t, a1: ptr c4m_dict_t): c4m_obj_t {.lc4m.}

proc c4m_marshal*(a0: c4m_obj_t, a1: ptr c4m_stream_t): void {.lc4m.}

proc c4m_unmarshal*(a0: ptr c4m_stream_t): c4m_obj_t {.lc4m.}

proc c4m_marshal_unmanaged_object*(
  a0: pointer,
  a1: ptr c4m_stream_t,
  a2: ptr c4m_dict_t,
  a3: ptr int64,
  a4: c4m_marshal_fn,
): void {.lc4m.}

proc c4m_unmarshal_unmanaged_object*(
  a0: csize_t, a1: ptr c4m_stream_t, a2: ptr c4m_dict_t, a3: c4m_unmarshal_fn
): pointer {.lc4m.}

proc c4m_dump_c_static_instance_code*(
  a0: c4m_obj_t, a1: cstring, a2: ptr c4m_utf8_t
): void {.lc4m.}

proc c4m_mixed_set_value*(
  a0: ptr c4m_mixed_t, a1: ptr c4m_type_t, a2: ptr pointer
): void {.lc4m.}

proc c4m_unbox_mixed*(
  a0: ptr c4m_mixed_t, a1: ptr c4m_type_t, a2: ptr pointer
): void {.lc4m.}

proc c4m_get_lbrak_const*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_get_comma_const*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_get_rbrak_const*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_get_lparen_const*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_get_rparen_const*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_get_arrow_const*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_get_backtick_const*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_get_asterisk_const*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_get_space_const*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_get_lbrace_const*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_get_rbrace_const*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_get_colon_const*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_get_colon_no_space_const*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_get_slash_const*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_get_period_const*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_get_empty_fmt_const*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_get_newline_const*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_in_parens*(a0: ptr c4m_str_t): ptr c4m_utf8_t {.lc4m.}

proc c4m_raw_int_parse*(
  a0: ptr c4m_utf8_t, a1: ptr c4m_compile_error_t, a2: ptr bool
): compiler_uint128_t {.lc4m.}

proc c4m_raw_hex_parse*(
  a0: cstring, a1: ptr c4m_compile_error_t
): compiler_uint128_t {.lc4m.}

proc c4m_init_literal_handling*(): void {.lc4m.}

proc c4m_register_literal*(
  a0: c4m_lit_syntax_t, a1: cstring, a2: c4m_builtin_t
): void {.lc4m.}

proc c4m_parse_simple_lit*(
  a0: ptr c4m_token_t, a1: ptr c4m_lit_syntax_t, a2: ptr ptr c4m_utf8_t
): c4m_compile_error_t {.lc4m.}

proc c4m_base_type_from_litmod*(
  a0: c4m_lit_syntax_t, a1: ptr c4m_utf8_t
): c4m_builtin_t {.lc4m.}

proc c4m_fix_litmod*(a0: ptr c4m_token_t, a1: ptr c4m_pnode_t): bool {.lc4m.}

proc c4m_base_format*(a0: ptr c4m_str_t, a1: cint): ptr c4m_utf8_t {.lc4m, varargs.}

proc c4m_str_vformat*(a0: ptr c4m_str_t, a1: ptr c4m_dict_t): ptr c4m_utf8_t {.lc4m.}

proc internal_c4m_str_format*(
  a0: ptr c4m_str_t, a1: cint
): ptr c4m_utf8_t {.cdecl, varargs, importc: "_c4m_str_format".}

proc internal_c4m_cstr_format*(
  a0: cstring, a1: cint
): ptr c4m_utf8_t {.cdecl, varargs, importc: "_c4m_cstr_format".}

proc c4m_cstr_array_format*(
  a0: cstring, a1: cint, a2: ptr ptr c4m_utf8_t
): ptr c4m_utf8_t {.lc4m.}

proc c4m_internal_fptostr*(d: cdouble, dest: array[24, cschar]): cint {.lc4m.}

proc c4m_resolve_path*(a0: ptr c4m_utf8_t): ptr c4m_utf8_t {.lc4m.}

proc c4m_path_tilde_expand*(a0: ptr c4m_utf8_t): ptr c4m_utf8_t {.lc4m.}

proc c4m_get_user_dir*(a0: ptr c4m_utf8_t): ptr c4m_utf8_t {.lc4m.}

proc c4m_get_current_directory*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_path_join*(a0: ptr c4m_list_t): ptr c4m_utf8_t {.lc4m.}

proc c4m_get_file_kind*(a0: ptr c4m_utf8_t): c4m_file_kind {.lc4m.}

proc internal_c4m_path_walk*(
  a0: ptr c4m_utf8_t
): ptr c4m_list_t {.cdecl, varargs, importc: "_c4m_path_walk".}

proc c4m_app_path*(): ptr c4m_utf8_t {.lc4m.}

proc c4m_path_trim_slashes*(a0: ptr c4m_str_t): ptr c4m_utf8_t {.lc4m.}

proc CRYPTO_set_mem_functions*(
  m: proc(a0: csize_t, a1: cstring, a2: cint): pointer {.cdecl.},
  r: proc(a0: pointer, a1: csize_t, a2: cstring, a3: cint): pointer {.cdecl.},
  f: proc(a0: pointer, a1: cstring, a2: cint): void {.cdecl.},
): cint {.lc4m.}

proc EVP_MD_CTX_new*(): EVP_MD_CTX {.lc4m.}

proc EVP_DigestInit_ex2*(a0: EVP_MD_CTX, a1: EVP_MD, a2: pointer): cint {.lc4m.}

proc EVP_DigestUpdate*(a0: ptr EVP_MD_CTX, a1: pointer, a2: csize_t): cint {.lc4m.}

proc EVP_DigestFinal_ex*(a0: ptr EVP_MD_CTX, a1: cstring, a2: ptr cuint): cint {.lc4m.}

proc EVP_MD_CTX_free*(a0: ptr EVP_MD_CTX): void {.lc4m.}

proc EVP_sha256*(): ptr EVP_MD {.lc4m.}

proc EVP_sha384*(): ptr EVP_MD {.lc4m.}

proc EVP_sha512*(): ptr EVP_MD {.lc4m.}

proc EVP_sha3_256*(): ptr EVP_MD {.lc4m.}

proc EVP_sha3_384*(): ptr EVP_MD {.lc4m.}

proc EVP_sha3_512*(): ptr EVP_MD {.lc4m.}

proc SHA1*(data: ptr uint8, count: csize_t, md_buf: ptr uint8): ptr uint8 {.lc4m.}

proc SHA224*(data: ptr uint8, count: csize_t, md_buf: ptr uint8): ptr uint8 {.lc4m.}

proc SHA256*(data: ptr uint8, count: csize_t, md_buf: ptr uint8): ptr uint8 {.lc4m.}

proc SHA512*(data: ptr uint8, count: csize_t, md_buf: ptr uint8): ptr uint8 {.lc4m.}

proc c4m_sha_init*(a0: ptr c4m_sha_t): void {.lc4m, varargs.}

proc c4m_sha_cstring_update*(a0: ptr c4m_sha_t, a1: cstring): void {.lc4m.}

proc c4m_sha_int_update*(a0: ptr c4m_sha_t, a1: uint64): void {.lc4m.}

proc c4m_sha_string_update*(a0: ptr c4m_sha_t, a1: ptr c4m_str_t): void {.lc4m.}

proc c4m_sha_buffer_update*(a0: ptr c4m_sha_t, a1: ptr c4m_buf_t): void {.lc4m.}

proc c4m_sha_finish*(a0: ptr c4m_sha_t): ptr c4m_buf_t {.lc4m.}

proc c4m_gc_openssl*(): void {.lc4m.}

proc c4m_vm_reset*(vm: ptr c4m_vm_t): void {.lc4m.}

proc c4m_vm_setup_runtime*(vm: ptr c4m_vm_t): void {.lc4m.}

proc c4m_vmthread_new*(vm: ptr c4m_vm_t): ptr c4m_vmthread_t {.lc4m.}

proc c4m_vmthread_run*(tstate: ptr c4m_vmthread_t): cint {.lc4m.}

proc c4m_vmthread_reset*(tstate: ptr c4m_vmthread_t): void {.lc4m.}

proc c4m_vm_attr_get*(
  tstate: ptr c4m_vmthread_t, key: ptr c4m_str_t, found: ptr bool
): ptr c4m_value_t {.lc4m.}

proc c4m_vm_attr_set*(
  tstate: ptr c4m_vmthread_t,
  key: ptr c4m_str_t,
  value: ptr c4m_value_t,
  lock: bool,
  override: bool,
  internal: bool,
): void {.lc4m.}

proc c4m_vm_attr_lock*(
  tstate: ptr c4m_vmthread_t, key: ptr c4m_str_t, on_write: bool
): void {.lc4m.}

proc c4m_vm_marshal*(
  vm: ptr c4m_vm_t, out_arg: ptr c4m_stream_t, memos: ptr c4m_dict_t, mid: ptr int64
): void {.lc4m.}

proc c4m_vm_unmarshal*(
  vm: ptr c4m_vm_t, in_arg: ptr c4m_stream_t, memos: ptr c4m_dict_t
): void {.lc4m.}

proc c4m_flags_copy*(a0: ptr c4m_flags_t): ptr c4m_flags_t {.lc4m.}

proc c4m_flags_add*(a0: ptr c4m_flags_t, a1: ptr c4m_flags_t): ptr c4m_flags_t {.lc4m.}

proc c4m_flags_sub*(a0: ptr c4m_flags_t, a1: ptr c4m_flags_t): ptr c4m_flags_t {.lc4m.}

proc c4m_flags_test*(a0: ptr c4m_flags_t, a1: ptr c4m_flags_t): ptr c4m_flags_t {.lc4m.}

proc c4m_flags_xor*(a0: ptr c4m_flags_t, a1: ptr c4m_flags_t): ptr c4m_flags_t {.lc4m.}

proc c4m_flags_eq*(a0: ptr c4m_flags_t, a1: ptr c4m_flags_t): bool {.lc4m.}

proc c4m_flags_len*(a0: ptr c4m_flags_t): uint64 {.lc4m.}

proc c4m_flags_index*(a0: ptr c4m_flags_t, a1: int64): bool {.lc4m.}

proc c4m_flags_set_index*(a0: ptr c4m_flags_t, a1: int64, a2: bool): void {.lc4m.}

proc c4m_clz*(a0: uint64): uint64 {.lc4m.}

proc c4m_wrapper_join*(a0: ptr c4m_list_t, a1: ptr c4m_str_t): ptr c4m_utf32_t {.lc4m.}

proc c4m_wrapper_hostname*(): ptr c4m_str_t {.lc4m.}

proc c4m_wrapper_os*(): ptr c4m_str_t {.lc4m.}

proc c4m_wrapper_arch*(): ptr c4m_str_t {.lc4m.}

proc c4m_wrapper_repr*(a0: c4m_obj_t): ptr c4m_str_t {.lc4m.}

proc c4m_wrapper_to_str*(a0: c4m_obj_t): ptr c4m_str_t {.lc4m.}

proc c4m_snap_column*(a0: ptr c4m_grid_t, a1: int64): void {.lc4m.}

proc c4m_get_c_backtrace*(): ptr c4m_grid_t {.lc4m.}

proc c4m_static_c_backtrace*(): void {.lc4m.}

proc c4m_set_crash_callback*(a0: proc(): void {.cdecl.}): void {.lc4m.}

proc c4m_set_show_trace_on_crash*(a0: bool): void {.lc4m.}

proc internal_c4m_set_package_search_path*(
  a0: ptr c4m_utf8_t
): void {.cdecl, varargs, importc: "_c4m_set_package_search_path".}

proc c4m_validate_module_info*(a0: ptr c4m_module_compile_ctx): bool {.lc4m.}

proc c4m_init_module_from_loc*(
  a0: ptr c4m_compile_ctx, a1: ptr c4m_str_t
): ptr c4m_module_compile_ctx {.lc4m.}

proc c4m_new_module_compile_ctx*(): ptr c4m_module_compile_ctx {.lc4m.}

proc c4m_get_module_summary_info*(a0: ptr c4m_compile_ctx): ptr c4m_grid_t {.lc4m.}

proc c4m_add_module_to_worklist*(
  a0: ptr c4m_compile_ctx, a1: ptr c4m_module_compile_ctx
): bool {.lc4m.}

proc c4m_package_from_path_prefix*(
  a0: ptr c4m_utf8_t, a1: ptr ptr c4m_utf8_t
): ptr c4m_utf8_t {.lc4m.}

proc c4m_find_module*(
  ctx: ptr c4m_compile_ctx,
  path: ptr c4m_str_t,
  module: ptr c4m_str_t,
  package: ptr c4m_str_t,
  relative_package: ptr c4m_str_t,
  relative_path: ptr c4m_str_t,
  fext: ptr c4m_list_t,
): ptr c4m_module_compile_ctx {.lc4m.}

proc c4m_new_compile_context*(a0: ptr c4m_str_t): ptr c4m_compile_ctx {.lc4m.}

proc c4m_compile_from_entry_point*(a0: ptr c4m_str_t): ptr c4m_compile_ctx {.lc4m.}

proc c4m_str_to_type*(a0: ptr c4m_utf8_t): ptr c4m_type_t {.lc4m.}

proc c4m_generate_code*(a0: ptr c4m_compile_ctx): ptr c4m_vm_t {.lc4m.}

proc c4m_format_error_message*(
  a0: ptr c4m_compile_error, a1: bool
): ptr c4m_str_t {.lc4m.}

proc c4m_format_errors*(a0: ptr c4m_compile_ctx): ptr c4m_grid_t {.lc4m.}

proc c4m_compile_extract_all_error_codes*(
  a0: ptr c4m_compile_ctx
): ptr c4m_list_t {.lc4m.}

proc c4m_err_code_to_str*(a0: c4m_compile_error_t): ptr c4m_utf8_t {.lc4m.}

proc c4m_base_add_error*(
  a0: ptr c4m_list_t,
  a1: c4m_compile_error_t,
  a2: ptr c4m_token_t,
  a3: c4m_err_severity_t,
): ptr c4m_compile_error {.lc4m, varargs.}

proc internal_c4m_add_error*(
  a0: ptr c4m_module_compile_ctx, a1: c4m_compile_error_t, a2: ptr c4m_tree_node_t
): ptr c4m_compile_error {.cdecl, varargs, importc: "_c4m_add_error".}

proc internal_c4m_add_warning*(
  a0: ptr c4m_module_compile_ctx, a1: c4m_compile_error_t, a2: ptr c4m_tree_node_t
): ptr c4m_compile_error {.cdecl, varargs, importc: "_c4m_add_warning".}

proc internal_c4m_add_info*(
  a0: ptr c4m_module_compile_ctx, a1: c4m_compile_error_t, a2: ptr c4m_tree_node_t
): ptr c4m_compile_error {.cdecl, varargs, importc: "_c4m_add_info".}

proc internal_c4m_add_spec_error*(
  a0: ptr c4m_spec_t, a1: c4m_compile_error_t, a2: ptr c4m_tree_node_t
): ptr c4m_compile_error {.cdecl, varargs, importc: "_c4m_add_spec_error".}

proc internal_c4m_add_spec_warning*(
  a0: ptr c4m_spec_t, a1: c4m_compile_error_t, a2: ptr c4m_tree_node_t
): ptr c4m_compile_error {.cdecl, varargs, importc: "_c4m_add_spec_warning".}

proc internal_c4m_add_spec_info*(
  a0: ptr c4m_spec_t, a1: c4m_compile_error_t, a2: ptr c4m_tree_node_t
): ptr c4m_compile_error {.cdecl, varargs, importc: "_c4m_add_spec_info".}

proc internal_c4m_error_from_token*(
  a0: ptr c4m_module_compile_ctx, a1: c4m_compile_error_t, a2: ptr c4m_token_t
): ptr c4m_compile_error {.cdecl, varargs, importc: "_c4m_error_from_token".}

proc internal_c4m_module_load_error*(
  a0: ptr c4m_module_compile_ctx, a1: c4m_compile_error_t
): void {.cdecl, varargs, importc: "_c4m_module_load_error".}

proc internal_c4m_module_load_warn*(
  a0: ptr c4m_module_compile_ctx, a1: c4m_compile_error_t
): void {.cdecl, varargs, importc: "_c4m_module_load_warn".}

proc c4m_new_error*(a0: cint): ptr c4m_compile_error {.lc4m.}

proc c4m_lex*(a0: ptr c4m_module_compile_ctx, a1: ptr c4m_stream_t): bool {.lc4m.}

proc c4m_format_one_token*(
  a0: ptr c4m_token_t, a1: ptr c4m_str_t
): ptr c4m_utf8_t {.lc4m.}

proc c4m_format_tokens*(a0: ptr c4m_module_compile_ctx): ptr c4m_grid_t {.lc4m.}

proc c4m_token_type_to_string*(a0: c4m_token_kind_t): ptr c4m_utf8_t {.lc4m.}

proc c4m_token_raw_content*(a0: ptr c4m_token_t): ptr c4m_utf8_t {.lc4m.}

proc c4m_parse*(a0: ptr c4m_module_compile_ctx): bool {.lc4m.}

proc c4m_parse_type*(a0: ptr c4m_module_compile_ctx): bool {.lc4m.}

proc c4m_format_parse_tree*(a0: ptr c4m_module_compile_ctx): ptr c4m_grid_t {.lc4m.}

proc c4m_print_parse_node*(a0: ptr c4m_tree_node_t): void {.lc4m.}

proc c4m_node_type_name*(a0: c4m_node_kind_t): ptr c4m_utf8_t {.lc4m.}

proc c4m_new_spec*(): ptr c4m_spec_t {.lc4m.}

proc c4m_get_attr_info*(
  a0: ptr c4m_spec_t, a1: ptr c4m_list_t
): ptr c4m_attr_info_t {.lc4m.}

proc c4m_cfg_enter_block*(
  a0: ptr c4m_cfg_node_t, a1: ptr c4m_tree_node_t
): ptr c4m_cfg_node_t {.lc4m.}

proc c4m_cfg_exit_block*(
  a0: ptr c4m_cfg_node_t, a1: ptr c4m_cfg_node_t, a2: ptr c4m_tree_node_t
): ptr c4m_cfg_node_t {.lc4m.}

proc c4m_cfg_block_new_branch_node*(
  a0: ptr c4m_cfg_node_t, a1: cint, a2: ptr c4m_utf8_t, a3: ptr c4m_tree_node_t
): ptr c4m_cfg_node_t {.lc4m.}

proc c4m_cfg_add_return*(
  a0: ptr c4m_cfg_node_t, a1: ptr c4m_tree_node_t, a2: ptr c4m_cfg_node_t
): ptr c4m_cfg_node_t {.lc4m.}

proc c4m_cfg_add_continue*(
  a0: ptr c4m_cfg_node_t, a1: ptr c4m_tree_node_t, a2: ptr c4m_utf8_t
): ptr c4m_cfg_node_t {.lc4m.}

proc c4m_cfg_add_break*(
  a0: ptr c4m_cfg_node_t, a1: ptr c4m_tree_node_t, a2: ptr c4m_utf8_t
): ptr c4m_cfg_node_t {.lc4m.}

proc c4m_cfg_add_def*(
  a0: ptr c4m_cfg_node_t,
  a1: ptr c4m_tree_node_t,
  a2: ptr c4m_symbol_t,
  a3: ptr c4m_list_t,
): ptr c4m_cfg_node_t {.lc4m.}

proc c4m_cfg_add_call*(
  a0: ptr c4m_cfg_node_t,
  a1: ptr c4m_tree_node_t,
  a2: ptr c4m_symbol_t,
  a3: ptr c4m_list_t,
): ptr c4m_cfg_node_t {.lc4m.}

proc c4m_cfg_add_use*(
  a0: ptr c4m_cfg_node_t, a1: ptr c4m_tree_node_t, a2: ptr c4m_symbol_t
): ptr c4m_cfg_node_t {.lc4m.}

proc c4m_cfg_repr*(a0: ptr c4m_cfg_node_t): ptr c4m_grid_t {.lc4m.}

proc c4m_cfg_analyze*(a0: ptr c4m_module_compile_ctx, a1: ptr c4m_dict_t): void {.lc4m.}

proc c4m_dict_copy*(dict: ptr c4m_dict_t): ptr c4m_dict_t {.lc4m.}

proc c4m_set_shallow_copy*(a0: ptr c4m_set_t): ptr c4m_set_t {.lc4m.}

proc c4m_set_to_xlist*(a0: ptr c4m_set_t): ptr c4m_list_t {.lc4m.}

proc c4m_ipaddr_set_address*(
  obj: ptr c4m_ipaddr_t, s: ptr c4m_str_t, port: uint16
): void {.lc4m.}

proc c4m_now*(): ptr c4m_duration_t {.lc4m.}

proc c4m_timestamp*(): ptr c4m_duration_t {.lc4m.}

proc c4m_process_cpu*(): ptr c4m_duration_t {.lc4m.}

proc c4m_thread_cpu*(): ptr c4m_duration_t {.lc4m.}

proc c4m_uptime*(): ptr c4m_duration_t {.lc4m.}

proc c4m_program_clock*(): ptr c4m_duration_t {.lc4m.}

proc c4m_init_program_timestamp*(): void {.lc4m.}

proc c4m_duration_diff*(
  a0: ptr c4m_duration_t, a1: ptr c4m_duration_t
): ptr c4m_duration_t {.lc4m.}

proc c4m_add_static_function*(a0: ptr c4m_utf8_t, a1: pointer): void {.lc4m.}

proc c4m_ffi_find_symbol*(a0: ptr c4m_utf8_t, a1: ptr c4m_list_t): pointer {.lc4m.}

proc c4m_lookup_ctype_id*(a0: cstring): int64 {.lc4m.}

proc c4m_ffi_arg_type_map*(a0: uint8): ptr c4m_ffi_type {.lc4m.}

proc c4m_ref_via_ffi_type*(a0: ptr c4m_box_t, a1: ptr c4m_ffi_type): pointer {.lc4m.}

proc ffi_prep_cif*(
  a0: ptr c4m_ffi_cif,
  a1: c4m_ffi_abi,
  a2: cuint,
  a3: ptr c4m_ffi_type,
  a4: ptr ptr c4m_ffi_type,
): c4m_ffi_status {.lc4m.}

proc ffi_prep_cif_var*(
  a0: ptr c4m_ffi_cif,
  a1: c4m_ffi_abi,
  a2: cuint,
  a3: cuint,
  a4: ptr c4m_ffi_type,
  a5: ptr ptr c4m_ffi_type,
): c4m_ffi_status {.lc4m.}

proc ffi_call*(
  a0: ptr c4m_ffi_cif, a1: pointer, a2: pointer, a3: ptr pointer
): void {.lc4m.}

proc internal_c4m_http_get*(
  a0: ptr c4m_str_t
): ptr c4m_basic_http_response_t {.cdecl, varargs, importc: "_c4m_http_get".}

proc internal_c4m_http_upload*(
  a0: ptr c4m_str_t, a1: ptr c4m_buf_t
): ptr c4m_basic_http_response_t {.cdecl, varargs, importc: "_c4m_http_upload".}

proc c4m_read_utf8_file*(a0: ptr c4m_str_t): ptr c4m_utf8_t {.lc4m.}

proc c4m_read_binary_file*(a0: ptr c4m_str_t): ptr c4m_buf_t {.lc4m.}
