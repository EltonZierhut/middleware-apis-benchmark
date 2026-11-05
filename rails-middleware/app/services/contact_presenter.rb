require "time"

# Converte o contrato upstream para o contrato público (OpenAPI).
module ContactPresenter
  module_function

  def call(c)
    {
      id: c["uuid"],
      name: c["name"],
      email: c["email"],
      job_title: c["job_title"],
      tags: c["tags"],
      lead_stage: c["lead_stage"].downcase.tr(" ", "_"),
      created_at: Time.at(c["created_at"]).utc.iso8601,
      custom_fields: c["cf"]
    }
  end
end
