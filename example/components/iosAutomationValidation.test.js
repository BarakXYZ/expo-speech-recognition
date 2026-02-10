const { validateResultInvariants } = require("./iosAutomationValidation");

function createValidCapture() {
  return {
    startCount: 1,
    endCount: 1,
    results: [
      {
        results: [
          {
            transcript: "hello world",
            confidence: 0.88,
            segments: [
              {
                startTimeMillis: 0,
                endTimeMillis: 420,
                confidence: 0.85,
              },
            ],
          },
        ],
      },
    ],
  };
}

describe("validateResultInvariants", () => {
  it("passes a valid capture", () => {
    const failures = validateResultInvariants({
      capture: createValidCapture(),
      maxAlternatives: 3,
      requireTranscript: true,
    });
    expect(failures).toHaveLength(0);
  });

  it("fails when maxAlternatives is exceeded", () => {
    const capture = createValidCapture();
    capture.results[0].results.push({
      transcript: "alt one",
      confidence: 0.7,
      segments: [],
    });
    capture.results[0].results.push({
      transcript: "alt two",
      confidence: 0.6,
      segments: [],
    });

    const failures = validateResultInvariants({
      capture,
      maxAlternatives: 2,
      requireTranscript: true,
    });

    expect(
      failures.some((failure) => failure.includes("exceeded maxAlternatives")),
    ).toBe(true);
  });

  it("fails when punctuation stripping is expected but punctuation is present", () => {
    const capture = createValidCapture();
    capture.results[0].results[0].transcript = "hello, world!";

    const failures = validateResultInvariants({
      capture,
      maxAlternatives: 3,
      requireTranscript: true,
      expectPunctuationStripped: true,
    });

    expect(
      failures.some((failure) =>
        failure.includes("Expected punctuation-stripped transcript"),
      ),
    ).toBe(true);
  });

  it("fails on out-of-range confidence and invalid segment timing", () => {
    const capture = createValidCapture();
    capture.results[0].results[0].confidence = 1.5;
    capture.results[0].results[0].segments = [
      {
        startTimeMillis: 350,
        endTimeMillis: 120,
        confidence: -1.2,
      },
    ];

    const failures = validateResultInvariants({
      capture,
      maxAlternatives: 3,
      requireTranscript: true,
    });

    expect(
      failures.some((failure) =>
        failure.includes("Result confidence out of bounds"),
      ),
    ).toBe(true);
    expect(
      failures.some((failure) =>
        failure.includes("Segment confidence out of bounds"),
      ),
    ).toBe(true);
    expect(
      failures.some((failure) =>
        failure.includes("Segment end precedes start"),
      ),
    ).toBe(true);
  });
});
