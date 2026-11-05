Rails.application.routes.draw do
  get "/health", to: "health#show"
  get "/platform/contacts", to: "contacts#index"
  get "/platform/contacts/:id", to: "contacts#show"
end
