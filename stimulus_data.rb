# frozen_string_literal: true

# Author:  Paul Sadauskas<paul@sadauskas.com>
# License: MIT

class StimulusData
  # Simplifies complicated Stimulus data attributes in HTML tags, which can be particularly
  # annoying with non-trivial controller names.
  #
  # It can also be chained using the "with" method, to provide different attributes on different
  # elements, excluding the `data-controller` attribute on all but the first.
  #
  # Examples:
  #
  # The following examples start with the following defined somewhere
  #
  #   stimulus_data = StimulusData.new("loader", values: {url: "/messages"})
  #
  # @example Using ERB
  #
  #   <div <%= stimulus_data %>/>
  #   #=> <div data-controller="loader" data-loader-url-value="/messages"/>
  #
  # @example Using Rails TagBuilder/TagHelper
  #
  #   tag.div(data: stimulus_data)
  #   #=> <div data-controller="loader" data-loader-url-value="/messages"/>
  #
  # @example Using HAML/Slim
  #
  #   %div{data: stimulus_data}
  #   #=> <div data-controller="loader" data-loader-url-value="/messages"/>
  #
  # @example Using #with
  #
  #   %div{data: stimulus_data}
  #     %div.spinner{data: stimulus_data.with(target: "spinner"}
  #     %button{data: stimulus_data.with(action: "showSpinner"}
  #     %button{data: stimulus_data.with(action: "hideSpinner"}
  #
  #   #=>
  #     <div data-controller="loader" data-loader-url-value="/messages">
  #       <div class="spinner" data-loader-target="spinner"></div>
  #       <button data-action="loader#showSpinner"/>
  #       <button data-action="loader#hideSpinner"/>
  #     </div>
  #
  attr_reader :controller, :actions, :target, :values, :outlets

  def initialize(controller,
                 action: nil, actions: [],
                 target: nil, values: {},
                 outlets: {},
                 include_controller: true)
    @controller = controller_name(controller)
    @actions = actions.push(action).compact
    @target = target
    @values = values
    @outlets = outlets
    @include_controller = include_controller
  end

  def with(action: nil, actions: [], target: nil, values: {}, outlets: {})
    self.class.new(controller, include_controller: false,
      action:, actions:, target:, values:, outlets:)
  end

  def data
    data = {}
    data["controller"] = controller if @include_controller

    if actions.present?
      data["action"] = actions.map do |action|
        event, method = action.split("->")
        event, method = nil, event if method.nil?
        [[event, controller].compact.join("->"), method].join("#")
      end.join(" ")
    end

    data["#{controller}-target"] = target.to_s.camelize(:lower) if target

    outlets.each do |outlet, selector|
      data["#{controller}-#{outlet.to_s.dasherize}-outlet"] = selector
    end

    values.each do |key, val|
      data["#{controller}-#{key.to_s.dasherize}-value"] = val
    end

    data.compact
  end
  alias_method :to_h, :data

  def to_s
    ActionView::Helpers::TagBuilder.new(nil).attributes(data:)
  end

  def inspect
    "#<StimulusData #{data.inspect}>"
  end

  # Lie and pretend we're a hash to anything that's checking
  # This lets HAML/Slim process the attributes like a Hash
  def is_a?(other)
    return true if other == Hash

    super(other)
  end
  delegate :each_pair, to: :to_h

  private

  def controller_name(controller)
    return kebab(controller.stimulus_controller) if controller.respond_to?(:stimulus_controller)

    case controller
    when Class then kebab(controller.name)
    when Symbol, String then kebab(controller)
    else
      kebab(controller.class.name)
    end
  end

  def kebab(str)
    str.to_s.underscore.dasherize.gsub("/", "--")
  end
end

