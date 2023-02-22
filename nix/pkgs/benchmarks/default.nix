{ repro
, runCommand
, writeText
, coreutils
, jq
, lastEnvChange
}:
let
  lastEnvChangeFile = writeText "lastEnvChange" lastEnvChange;
  bench = repro.repro.components.benchmarks.repro-benchmark;

  # Generate repro benchmark results as HTML.
  repro-benchmark-results-html = (runCommand "repro-benchmark-results-html" { }
    ''
      ${coreutils}/bin/mkdir -p $out
      cp ${lastEnvChangeFile} $out/lastEnvChange
      ${bench}/bin/repro-benchmark --output $out/results.html --regress cpuTime:iters --regress allocated:iters --regress numGcs:iters +RTS -T
    ''
  ).overrideAttrs
    (drv: {
      requiredSystemFeatures = (drv.requiredSystemFeatures or [ ]) ++ [ "benchmark" ];
    });

  # Generate repro benchmark results as JSON.
  repro-benchmark-results-json = (runCommand "repro-benchmark-results-json" { }
    ''
      ${coreutils}/bin/mkdir -p $out
      cp ${lastEnvChangeFile} $out/lastEnvChange
      ${bench}/bin/repro-benchmark --template json --output $out/results.json --regress cpuTime:iters --regress allocated:iters --regress numGcs:iters +RTS -T
    ''
  ).overrideAttrs
    (drv: {
      requiredSystemFeatures = (drv.requiredSystemFeatures or [ ]) ++ [ "benchmark" ];
    });


  # Convert repro benchmark results to the format expected
  # by
  # https://github.com/benchmark-action/github-action-benchmark
  #
  # For each benchmark, we report:
  # - the mean execution time, including the standard deviation.
  #
  # - the outlier variance (the degree to which the standard
  #   deviation is inflated by outlying measurements).
  #
  # - each OLS regression measured by the benchmark run, and
  # - its R² value as a tooltip.
  repro-benchmark-results-github-action-benchmark =
    let
      jqscript = writeText "extract-criterion.jq" ''
        [.[]
        | .reportName as $basename
        | .reportAnalysis as $report
        | { name: "\($basename): mean time", unit: "mean time", value: $report.anMean.estPoint, range: $report.anStdDev.estPoint }
        , { name: "\($basename): outlier variance", unit: "outlier variance", value: $report.anOutlierVar.ovFraction }
        , $report.anRegress[] as $regress
        | { name: "\($basename): \($regress.regResponder)", unit: "\($regress.regResponder)/iter", value: $regress.regCoeffs.iters.estPoint, extra: "R²: \($regress.regRSquare.estPoint)" }
        ]
      '';
    in
    (runCommand "repro-benchmark-results-github-action-benchmark" { }
      ''
        ${coreutils}/bin/mkdir -p $out
        cp ${lastEnvChangeFile} $out/lastEnvChange
        ${jq}/bin/jq -f ${jqscript} ${repro-benchmark-results-json}/results.json > $out/results.json
      ''
    );
in
{
  inherit repro-benchmark-results-html repro-benchmark-results-json repro-benchmark-results-github-action-benchmark;
}
