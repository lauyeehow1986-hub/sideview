# print shows the table

    Code
      print(sv_stack_check(wave1, wave2))
    Output
      Stack 2 tables: 4 rows, 4 columns.
      1 column changes type.
       Column wave1 wave2                       Status
          AGE   num   chr type differs -> as.character
          SEX   chr   chr                           ok
         SITE     -   int  only in wave2 (NA in wave1)
      dplyr::bind_rows(wave1 = dplyr::mutate(wave1, AGE = as.character(AGE)), wave2 = wave2, .id = "source")

