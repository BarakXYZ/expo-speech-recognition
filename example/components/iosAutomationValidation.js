const punctuationRegex = /[.,!?;:"'()[\]{}\-—–…]/;

function validateResultInvariants(params) {
  const { capture, maxAlternatives, requireTranscript, expectPunctuationStripped } = params;
  const failures = [];
  const flatResults = capture.results.flatMap((event) => event.results);

  if (capture.startCount < 1) {
    failures.push("Expected at least one start event.");
  }
  if (capture.endCount < 1) {
    failures.push("Expected at least one end event.");
  }

  if (requireTranscript && flatResults.length < 1) {
    failures.push("Expected at least one transcript result.");
  }

  for (const event of capture.results) {
    if (event.results.length > maxAlternatives) {
      failures.push(
        `Result event exceeded maxAlternatives (${event.results.length} > ${maxAlternatives}).`,
      );
    }
  }

  for (const result of flatResults) {
    if (result.confidence < -1 || result.confidence > 1) {
      failures.push(`Result confidence out of bounds: ${result.confidence}.`);
    }

    if (expectPunctuationStripped && punctuationRegex.test(result.transcript)) {
      failures.push(
        `Expected punctuation-stripped transcript, got: "${result.transcript}"`,
      );
    }

    for (const segment of result.segments) {
      if (segment.confidence < -1 || segment.confidence > 1) {
        failures.push(`Segment confidence out of bounds: ${segment.confidence}.`);
      }
      if (segment.startTimeMillis < 0 || segment.endTimeMillis < 0) {
        failures.push(
          `Segment timestamps must be non-negative. Got ${segment.startTimeMillis}-${segment.endTimeMillis}.`,
        );
      }
      if (segment.endTimeMillis < segment.startTimeMillis) {
        failures.push(
          `Segment end precedes start: ${segment.startTimeMillis}-${segment.endTimeMillis}.`,
        );
      }
    }
  }

  return failures;
}

module.exports = {
  validateResultInvariants,
};
