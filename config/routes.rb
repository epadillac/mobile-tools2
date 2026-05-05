Rails.application.routes.draw do
  # Reveal Rails' boot health to load balancers / kamal-proxy. Returns 200
  # when the app has fully booted, 500 when it has not. Required by
  # `proxy.healthcheck.path: /up` in config/deploy.yml.
  get "up" => "rails/health#show", as: :rails_health_check

  resources :split_checks, only: %i[new create show] do
    collection do
      get :demo
      get :manual
    end
  end

  resources :invoices, only: %i[new create show] do
    member do
      post :verify
      get  :datos_fiscales
      post :lookup_rfc
      post :generate_invoice
      get  :download_pdf
      get  :download_xml
      get  :factura_lista
    end
  end

  resources :components, only: :index

  namespace :components do
    resource :alert, only: :show do
      collection do
        get :result
      end
    end

    resource :barcode_scanner, only: :show

    resource :biometrics_lock, only: :show

    resource :button, only: :show do
      collection do
        get :text
        get :image
        get :left
        get :result
      end
    end

    resource :document_scanner, only: :show

    resource :form, only: %i[new create show]

    resource :haptic, only: :show

    resource :location, only: :show

    resource :menu, only: :show do
      collection do
        get :result
      end
    end

    resource :nfc, only: :show

    resource :notification_token, only: :show

    resource :permissions, only: :show

    resource :review_prompt, only: :show

    resources :searches, only: %i[index show]

    resource :share, only: :show do
      collection do
        get :current
        get :custom
      end
    end

    resource :theme, only: :show

    resource :toast, only: :show
  end

  # root "components#index"
  root 'split_checks#new'
end
