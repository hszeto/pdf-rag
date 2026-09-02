# The plan screen's row order and labels.
#
# The order is fixed by the spec (R7.3) and is not the same as a hash's natural
# order, so it lives here rather than being derived from the field list. The
# labels are written out because humanize turns :copay_primary_care into
# "Copay primary care", which is not what a reader should see.
class PlanPresenter
  # [ field key, label, emphasis ]
  #
  # :fact marks the numbers people actually opened the app to find. Those render
  # at the larger size the spec requires for key figures; everything else is
  # supporting detail.
  ROWS = [
    [ :member_name,            "Name",                   :detail ],
    [ :plan_type,              "Plan Type",              :detail ],
    [ :plan_name,              "Plan Name",              :detail ],
    [ :insurance_id,           "Insurance ID",           :detail ],
    [ :copay_primary_care,     "Primary Care Copay",     :fact ],
    [ :copay_specialist,       "Specialist Copay",       :fact ],
    [ :deductible,             "Deductible",             :fact ],
    [ :plan_year,              "Plan Year",              :detail ],
    [ :customer_service_phone, "Customer Service Phone", :detail ]
  ].freeze

  MISSING_TEXT = "Not found in your document".freeze

  def self.keys = ROWS.map(&:first)
end
