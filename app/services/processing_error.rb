# Every way an upload can fail, each carrying the exact words the user sees.
#
# Keeping the copy on the error itself means controllers rescue one type and
# render one partial, which is what makes R7.5's "never a dead end" hold
# everywhere rather than at each call site that remembered to handle it.
#
# Copy avoids "upload", "AI", "session" and other technical vocabulary (R7.1).
class ProcessingError < StandardError
  def user_message = "Something went wrong. Please try again."

  class NotAPdf < ProcessingError
    def user_message
      "We can only read PDF files right now. Please add your document as a PDF."
    end
  end

  class TooLarge < ProcessingError
    def user_message
      "That file is too big for us to read. Please add a file smaller than 15 MB."
    end
  end

  class Missing < ProcessingError
    def user_message = "We did not get a file. Please choose your document and try again."
  end

  class Locked < ProcessingError
    def user_message
      "This file is locked. Please add a copy that does not need a password."
    end
  end

  class Damaged < ProcessingError
    def user_message = "We could not open this file. It may be damaged."
  end

  # A scanned or photographed document: it opens fine, but holds pictures rather
  # than words. Reading those is deferred (D3), so this is a dead end for now.
  class Unreadable < ProcessingError
    def user_message
      "We could not find any words in this document. If it is a photo or a scan, " \
      "please try a version you can select text in."
    end
  end

  # Raised when the cache write fails, so an upload never *looks* like it worked
  # and then vanishes on the next request (R3.6).
  class StorageFailure < ProcessingError
    def user_message = "We could not hold on to your document just now. Please try again."
  end

  class EmptyQuestion < ProcessingError
    def user_message = "Please type a question first."
  end

  class NoDocument < ProcessingError
    def user_message = "Please add your document first."
  end

# Structural content that asks a PDF viewer to execute something. Carries which
# signal caused the refusal, so support can answer "why was mine rejected"
# (R2.2), and so the reader is told something specific rather than "no".
class Unsafe < ProcessingError
  attr_reader :signal

  def initialize(signal)
    @signal = signal
    super("unsafe pdf: #{signal}")
  end

  def user_message
    "This PDF contains #{PdfSafetyPolicy.label_for(signal)}, so we did not open it. " \
    "Please try a different file."
  end
end

class NotReady < ProcessingError
  def user_message = "We are still reading this document. Please try again in a moment."
end

  class ServiceUnavailable < ProcessingError
    def user_message = "We are having trouble reading documents right now. Please try again in a moment."
  end

  # A daily cap, as opposed to a passing rate limit. Telling someone to try again
  # in a moment is untrue when the budget does not reset until tomorrow, and
  # sends them back to retry something that cannot work.
  class QuotaExhausted < ServiceUnavailable
    def user_message
      "We have reached today's limit for reading documents. Please try again tomorrow."
    end
  end
end
