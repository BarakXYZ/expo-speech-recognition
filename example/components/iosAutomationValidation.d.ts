export type ValidationSegment = {
  startTimeMillis: number;
  endTimeMillis: number;
  confidence: number;
};

export type ValidationResult = {
  transcript: string;
  confidence: number;
  segments: ValidationSegment[];
};

export type ValidationResultEvent = {
  results: ValidationResult[];
};

export type ValidationCapture = {
  startCount: number;
  endCount: number;
  results: ValidationResultEvent[];
};

export type ValidateParams = {
  capture: ValidationCapture;
  maxAlternatives: number;
  requireTranscript: boolean;
  expectPunctuationStripped?: boolean;
};

export function validateResultInvariants(params: ValidateParams): string[];
