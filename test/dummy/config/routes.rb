Rails.application.routes.draw do
  mount Xeno::Engine => "/agent"
end
