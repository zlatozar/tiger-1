type temp
val new_temp : unit -> temp
val string_of_temp : temp -> string

type label
val new_label : unit -> label
val named_label : string -> label
val string_of_label : label -> string
