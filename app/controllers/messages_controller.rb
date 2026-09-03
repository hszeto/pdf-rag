class MessagesController < ApplicationController
  def create
    document = Document.live.find_by(id: params[:document_id])
    raise ProcessingError::NoDocument if document.nil?
    raise ProcessingError::NotReady unless document.ready?

    QuestionAnswerer.new(document).call(params[:question])

    redirect_to document_path(document)
  rescue ProcessingError => e
    # Rendered rather than redirected so the message arrives on the document the
    # reader is already looking at, keeping their place and their history.
    @document = document
    flash.now[:alert] = e.user_message
    return redirect_to(root_path, alert: e.user_message) if @document.nil?

    render "documents/show", status: :unprocessable_entity
  end
end
