let () =
  Alcotest.run "propagate unit tests"
    [
      "core (stages 1-4)", Core_tests.tests;
      "exceptions (stage 8)", Exception_tests.tests;
      "cutoff (stage 9)", Cutoff_tests.tests;
      "cycles (stage 11)", Cycle_tests.tests;
      "reentrancy (stage 12)", Reentrancy_tests.tests;
      "memory (stage 13)", Memory_tests.tests;
    ]
