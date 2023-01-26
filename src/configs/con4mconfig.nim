## This variable represents the current config.  The con4m
## macro will also inject a variable with more config state, which we
## will use for config file layering.
##
## This will create a number of types for us.

import con4m, options, nimutils, tables

const defaultKeyPriority = 500

con4mDef(Sami):
  attr(config_path,
       [string],
       @[".", "~"],
       doc = "The path to search for other config files. " &
       "This can be specified at the command-line with an early flag."
  )
  attr(config_filename,
       string,
       "sami.conf",
       doc = "The config filename; also can be set from the command line")
  attr(default_command, string,
       required = false,
       doc = "When this command runs, if no command line arguments are " &
             "provided, if this value is set, the command will run, " &
             "using the configuration from the configuration file.")
  attr(color, bool, false, doc = "Do you want ansi output?")
  attr(log_level, string, "info",
       doc = "Controls the log-level for what gets output to the 'log' topic.")
  attr(sami_log_level, string, "warn",
       doc = "Controls the log-level for status messages getting put into " &
             "the SAMI_ERRORS field, during SAMI creation. These will only " &
             "be messages relevent to that SAMI's creation process.")
  attr(dry_run, bool, false)
  attr(ignore_broken_conf, bool, true)
  attr(con4m_pinpoint, bool, true)  # Non-advertised as well.
  attr(con4m_traces, bool, false)   # Non-advertised. Not in 'defaults'.
  attr(cache_fd_limit, int, 20) # Def. is low to avoid probs in constrained envs
  attr(publish_audit, bool, defaultVal = false)
  attr(artifact_search_path, [string], @["."])
  attr(ignore_patterns, [string],
       @[".*/**", "*.txt", "*.json"],
       doc = "File system patterns to ignore for SAMI insertion ONLY. " &
             "Other operations depend on the presence of a SAMI in a " &
             "file, so this is not used in those situations.")
  attr(recursive, bool, true)
  attr(can_dump, bool, true)
  attr(can_load, bool, true)
  attr(allow_external_config, bool, true)
  attr(publish_defaults,
       bool,
       defaultVal = false,
       doc = "When true, publishes config used to the 'defaults' topic")
  attr(publish_unmarked,
       bool,
       defaultVal = true,
       doc = "When publishing extractions, whether to also provide the " &
             "list of artifacts scanned where SAMIs were not found, but " &
             "would have been extracted, had they been there.")

  section(key, allowedSubSections = @["*", "*.json", "*.binary"]):
    attr(required,
         bool,
         defaultVal = false,
         doc = "When true, fail to WRITE a SAMI if no value is found " &
           "for the key via any allowed plugin.")
    attr(system,
         bool,
         defaultVal = false,
         doc = "these fields CANNOT be customzied in any way;" &
               "the system sets them outside the scope of the plugin system.")
    attr(squash,
         bool,
         doc = "If there's an existing SAMI we are incorporating, " &
         "remove this key in the old SAMI if squash is true when possible",
         defaultVal = true,
         lockOnWrite = true)
    attr(standard,
         bool,
         defaultVal = false,
         doc = "These fields are part of the draft SAMI standard, " &
               "meaning they are NOT custom fields.  If you set " &
               "this to 'true' and it's not actually standard, your " &
               "key is never getting written!")
    attr(must_force,
         bool,
         defaultVal = false,
         doc = "If this is true, the key only will be turned on if " &
              "a command-line flag was passed to force adding this flag.")
    attr(skip,
         bool,
         defaultVal = false,
         doc = "If not required by the spec, skip writing this key," &
               " even if its value could be computed. Will also be " &
               "skipped if found in a nested SAMI")
    attr(in_ptr,
         bool,
         defaultVal = false,
         doc = "If the key is to be injected, should it appear in the pointer" &
               " (if used; ignored otherwise)?")
    attr(output_order,
         int,
         defaultVal = defaultKeyPriority,
         doc = "Should not be set on custom keys.")
    attr(since,
         string,
         required = false,
         doc = "When did this get added to the spec (if it's a spec key)")
    attr(type, string, lockOnWrite = true, required = true)
    attr(value,
         @x,
         doc = "This is the value set when the 'conffile' plugin runs. " &
           "The conffile plugin can handle any key, but you can still " &
           "configure it to set priority ordering, so you have fine-" &
           "grained control over when the conf file takes precedence " &
           "over the other plugins.",
         required = false)
    attr(codec,
         bool,
         defaultVal = false,
         doc = "If true, then this key is settable by plugins marked codec.")
    attr(docstring,
         string,
         required = false,
         doc = "documentation for the key.")
  section(plugin, allowedSubSections = @["*"]):
    attr(priority,
         int,
         required = true,
         defaultVal = 50,
         doc = "Vs other plugins, where should this run?  Lower goes first." &
               "For codecs, this controls which codec will have priority " &
               "for making the choice on whether to handle a particular " &
               "artifact.  Codecs always get to write their keys first. For " &
               "other plugins, it determines the order in which they get to " &
               "write their keys.")
    attr(ignore,
         [string],
         defaultVal = @[])
    attr(codec,
         bool,
         required = true,
         defaultVal = false,
         lockOnWrite = true)
         #doc = "Is this plugin also a codec?")
    attr(keys,
         [string],
         required = true,
         lockOnWrite = true)
         #doc = "List of keys that this plugin might set. We use this to " &
         #      "skip running unnecessary plugins, if plugins with higher" &
         #      "priorities have already filled in all the appropriate keys.")
    attr(enabled, bool, defaultVal = true, doc = "Turn off this plugin.")
         #doc = "A list of keys that you do NOT want to take from this plugin.")
    attr(overrides,
         [string],
         defaultVal = @[])
         #doc = "A list of keys that you want to force-write when it is this " &
         #     "plugin's turn to write, even if higher priority plugins have " &
         #     "already written those keys. Note that this can't be used with" &
         #     " system or codec keys.")
    attr(uses_fstream,
         bool,
         defaultVal = true)
         #doc        = "set this to true if the codec or plugin *requires* " &
         #             "access to a file object. If the plugin reads from the" &
         #             " artifact itself, or writes to it (in the case of a" &
         #             " codec), then this value should be true. But some " &
         #             " codecs might not directly open a re-sharable file " &
         #             " pointer, for instance, one for a docker container.")
    attr(docstring,
         string,
         required = false)
         #doc = "Documentation for the plugin.")
  section(sink, allowedSubSections = @["*"]):
    attr(uses_secret, bool, defaultVal = false)
    attr(uses_uid, bool, defaultVal = false)
    attr(uses_filename, bool, defaultVal = false)
    attr(uses_uri, bool, defaultVal = false)
    attr(uses_region, bool, defaultVal = false)
    attr(uses_headers, bool, defaultVal = false)
    attr(uses_cacheid, bool, defaultVal = false)
    attr(uses_aux, bool, defaultVal = false)
    attr(needs_secret, bool, defaultVal = false)
    attr(needs_uid, bool, defaultVal = false)
    attr(needs_filename, bool, defaultVal = false)
    attr(needs_uri, bool, defaultVal = false)
    attr(needs_region, bool, defaultVal = false)
    attr(needs_aux, bool, defaultVal = false)
    attr(needs_headers, bool, defaultVal = false)
    attr(needs_cacheid, bool, defaultVal = false)
    attr(docstring, string, required = false)
