class MessagesController < ApplicationController
  # For dom_id, so the redirect below and the chat partial agree on the anchor
  # without either hard-coding its shape.
  include ActionView::RecordIdentifier

  def create
    document = Document.live.find_by(id: params[:document_id])
    raise ProcessingError::NoDocument if document.nil?
    raise ProcessingError::NotReady unless document.ready?

    QuestionAnswerer.new(document).call(params[:question])

    # Land the reader on the answer they just asked for, not the top of a page
    # that grows with every question (R2.3). QuestionAnswerer returns the answer
    # rather than the row, so the newest message is what to anchor to.
    newest = document.messages.ordered.last
    redirect_to document_path(document, anchor: newest && dom_id(newest))
  rescue ProcessingError => e
    # Rendered rather than redirected so the message arrives on the document the
    # reader is already looking at, keeping their place and their history.
    @document = document
    flash.now[:alert] = e.user_message
    return redirect_to(root_path, alert: e.user_message) if @document.nil?

    render "documents/show", status: :unprocessable_entity
  end
end
